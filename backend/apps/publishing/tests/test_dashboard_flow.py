"""Publishing from the dashboard (contract § 14): create, upload, process, publish, withdraw,
replace, edit; users and journal pages; purge."""

import base64
import json
import uuid
from datetime import datetime, timedelta
from io import StringIO

import pytest
from django.contrib.sessions.backends.db import SessionStore
from django.core.management import call_command
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.utils import timezone

from apps.accounts.models import Account
from apps.installations.models import Installation
from apps.publishing import services
from apps.publishing.catalog import published_catalog
from apps.publishing.models import AdminLogEntry, PublishedItem
from apps.shares.models import Share
from conftest import make_installation, make_purchase

State = PublishedItem.State

NEW_LANDSCAPE = {
    "kind": "paysage",
    "item_id": "lac-brume",
    "nom": "  Lac dans   la brume ",
    "gratuit": "premium",
    "alias": "Lac, brume du matin, lac",
    "theme": "nature",
    "eclairs": "on",
    "son_1": "vent",
    "niveau_son_1": "30",
    "musique_1": "piano-doux",
    "niveau_musique_1": "20",
}
TASK_ARN = "arn:aws:ecs:us-east-1:123456789012:task/ev-test/0123456789abcdef"


def create(admin_client, **overrides):
    data = {**NEW_LANDSCAPE, **overrides}
    return admin_client.post("/tableau/elements/nouveau", data)


def expect_run_task(aws_stubs, element_id, response=None):
    stubber = aws_stubs("ecs")
    stubber.add_response(
        "run_task",
        response or {"tasks": [{"taskArn": TASK_ARN}], "failures": []},
        expected_params={
            # ADR § 12.5: no launch type nor capacity provider (cluster default), no override
            # but the command, the task definition's tags.
            "cluster": "ev-test",
            "taskDefinition": "ev-test-media",
            "count": 1,
            "networkConfiguration": {
                "awsvpcConfiguration": {
                    "subnets": ["subnet-aaa", "subnet-bbb"],
                    "securityGroups": ["sg-media"],
                    "assignPublicIp": "DISABLED",
                }
            },
            "overrides": {
                "containerOverrides": [
                    {
                        "name": "media",
                        "command": ["python", "manage.py", "process_media", str(element_id)],
                    }
                ]
            },
            "propagateTags": "TASK_DEFINITION",
            "startedBy": "ev-tableau",
        },
    )
    return stubber


def start_upload(admin_client, item, extension="mp4"):
    return admin_client.post(f"/tableau/elements/{item.pk}/envoi", {"extension": extension})


def finish(admin_client, item, upload_id):
    return admin_client.post(f"/tableau/elements/{item.pk}/envoi-termine", {"upload_id": upload_id})


def processed(item, *, ambiance=True):
    """What the media task records at the end of a successful run."""
    PublishedItem.objects.filter(pk=item.pk).update(
        state=State.PRET, pending_has_ambiance=ambiance, pending_info={"video": {"crf": 30}}
    )
    item.refresh_from_db()


@pytest.mark.django_db
def test_create_a_landscape(admin_client, admin_account):
    response = create(admin_client)
    item = PublishedItem.objects.get()
    assert response.status_code == 302
    assert response["Location"] == f"/tableau/elements/{item.pk}?message=cree"
    assert item.kind == "paysage" and item.item_id == "lac-brume"
    assert item.nom == "Lac dans la brume"
    assert item.alias == ["lac", "brume du matin"]
    assert item.theme == "nature" and item.eclairs and not item.gratuit
    assert item.mix == {
        "sons": [{"id": "vent", "niveau": 30}],
        "musique": [{"id": "piano-doux", "niveau": 20}],
    }
    assert item.state == State.BROUILLON and not item.en_catalogue
    assert item.created_by_id == admin_account.pk
    entry = AdminLogEntry.objects.get()
    assert (entry.action, entry.element_id, entry.element_label) == (
        "creation",
        item.pk,
        "lac-brume",
    )
    page = admin_client.get(response["Location"])
    assert page.status_code == 200
    html = page.content.decode()
    assert "Élément créé" in html and "Envoyer le fichier" in html
    assert 'accept=".mp4,.mov,.webm"' in html
    assert "tableau/element.js" in html


@pytest.mark.django_db
def test_a_sound_ignores_landscape_fields(admin_client):
    response = create(admin_client, kind="son", item_id="vent-doux", nom="Vent doux")
    assert response.status_code == 302
    item = PublishedItem.objects.get()
    assert item.kind == "son" and item.theme == "" and not item.eclairs and item.mix == {}


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"item_id": "Lac"}, "minuscules"),
        ({"item_id": "lc"}, "3 à 40"),
        ({"item_id": "lac--brume"}, "minuscules"),
        ({"item_id": "-lac"}, "minuscules"),
        ({"item_id": "a" * 41}, "40"),
        ({"item_id": "vent"}, "catalogue de base"),
        ({"item_id": "cascade-foret"}, "catalogue de base"),
        ({"item_id": "tonnerre-coup-01"}, "catalogue de base"),
        ({"item_id": "sous-bois"}, "catalogue de base"),
        ({"item_id": "ambiance-lac"}, "réservé"),
        ({"nom": "L"}, "2"),
        ({"nom": "x" * 41}, "40"),
        ({"alias": ",".join(f"a{i}" for i in range(11))}, "10 alias"),
        ({"alias": "x" * 41}, "40 caractères"),
        ({"theme": ""}, "Nature ou Urbain"),
        ({"theme": "imaginaire"}, "valide"),
        ({"kind": "decor"}, "valide"),
        ({"son_1": "ambiance-pluie-ville"}, "valide"),
        ({"son_1": "tonnerre-coup-01"}, "valide"),
        ({"son_2": "vent", "niveau_son_2": "10"}, "Déjà dans le mix"),
        ({"niveau_son_1": "0"}, "supérieure ou égale à 1"),
        ({"niveau_son_1": ""}, "Niveau de 1 à 100"),
    ],
)
def test_invalid_new_elements_are_refused(admin_client, overrides, message):
    response = create(admin_client, **overrides)
    assert response.status_code == 400
    assert message in response.content.decode()
    assert not PublishedItem.objects.exists()


@pytest.mark.django_db
def test_an_id_is_never_reused_even_withdrawn(admin_client):
    PublishedItem.objects.create(kind="son", item_id="lac-brume", nom="Ancien", state="retire")
    response = create(admin_client)
    assert response.status_code == 400
    assert "déjà pris" in response.content.decode()


@pytest.mark.django_db
def test_upload_form_is_signed_for_one_source(admin_client, admin_account):
    create(admin_client)
    item = PublishedItem.objects.get()
    response = start_upload(admin_client, item, "MP4")
    assert response.status_code == 200
    body = response.json()
    upload_id = uuid.UUID(body["upload_id"])
    assert body["url"] == "https://ev-test-content.s3.us-east-1.amazonaws.com/"
    fields = body["fields"]
    assert fields["key"] == f"uploads/{upload_id}/source"
    assert fields["Content-Type"] == "video/mp4"
    policy = json.loads(base64.b64decode(fields["policy"]))
    conditions = policy["conditions"]
    assert {"bucket": "ev-test-content"} in conditions
    assert {"key": f"uploads/{upload_id}/source"} in conditions
    assert {"Content-Type": "video/mp4"} in conditions
    assert ["content-length-range", 1, 300_000_000] in conditions
    # No ACL (bucket owner enforced); valid 15 minutes at most (temporary role credentials).
    assert "acl" not in fields and not any("acl" in json.dumps(c) for c in conditions)
    expiration = datetime.fromisoformat(policy["expiration"].replace("Z", "+00:00"))
    assert expiration <= timezone.now() + timedelta(seconds=901)
    item.refresh_from_db()
    assert item.state == State.ENVOI and item.upload_id == upload_id and item.pending_rev == 1
    assert AdminLogEntry.objects.filter(action="envoi", element=item).count() == 1
    assert response["Cache-Control"] == "no-store"


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("kind", "extension", "content_type"),
    [
        ("paysage", "mov", "video/quicktime"),
        ("paysage", "webm", "video/webm"),
        ("son", "wav", "audio/wav"),
        ("son", "mp3", "audio/mpeg"),
        ("musique", "ogg", "audio/ogg"),
        ("musique", "m4a", "audio/mp4"),
        ("son", "flac", "audio/flac"),
    ],
)
def test_accepted_source_types(admin_client, kind, extension, content_type):
    item = PublishedItem.objects.create(kind=kind, item_id="essai", nom="Essai")
    response = start_upload(admin_client, item, extension)
    assert response.status_code == 200
    assert response.json()["fields"]["Content-Type"] == content_type


@pytest.mark.django_db
@pytest.mark.parametrize(("kind", "extension"), [("paysage", "wav"), ("son", "mp4"), ("son", "")])
def test_other_source_types_are_refused(admin_client, kind, extension):
    item = PublishedItem.objects.create(kind=kind, item_id="essai", nom="Essai")
    response = start_upload(admin_client, item, extension)
    assert response.status_code == 400
    item.refresh_from_db()
    assert item.state == State.BROUILLON


@pytest.mark.django_db
def test_upload_unavailable_without_a_bucket(admin_client, settings):
    settings.CONTENT_BUCKET = ""
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    response = start_upload(admin_client, item, "wav")
    assert response.status_code == 503
    assert response.json()["error"] == "upload_unavailable"


@pytest.mark.django_db
def test_upload_unavailable_without_credentials(admin_client, monkeypatch):
    from botocore.exceptions import NoCredentialsError

    from apps.publishing import aws

    def no_credentials(**kwargs):
        raise NoCredentialsError()

    monkeypatch.setattr(aws.client("s3"), "generate_presigned_post", no_credentials)
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    response = start_upload(admin_client, item, "wav")
    assert response.status_code == 503
    item.refresh_from_db()
    assert item.state == State.BROUILLON


@pytest.mark.django_db
def test_end_of_upload_starts_the_media_task_once(admin_client, aws_stubs):
    create(admin_client)
    item = PublishedItem.objects.get()
    upload_id = start_upload(admin_client, item).json()["upload_id"]
    stubber = expect_run_task(aws_stubs, item.pk)
    response = finish(admin_client, item, upload_id)
    assert response.status_code == 200
    assert response.json() == {"etat": "traitement", "detail": ""}
    stubber.assert_no_pending_responses()
    item.refresh_from_db()
    assert item.state == State.TRAITEMENT and item.processing_started_at is not None
    # A second notification (double click) does not start a second task.
    assert finish(admin_client, item, upload_id).status_code == 409
    assert finish(admin_client, item, str(uuid.uuid4())).status_code == 409
    assert finish(admin_client, item, "pas-un-uuid").status_code == 409
    state = admin_client.get(f"/tableau/elements/{item.pk}/etat")
    assert state.json() == {"etat": "traitement", "detail": ""}
    page = admin_client.get(f"/tableau/elements/{item.pk}").content.decode()
    assert 'data-suivre="1"' in page and "se met à jour seule" in page


@pytest.mark.django_db
def test_media_task_refused_by_ecs_is_a_failure(admin_client, aws_stubs):
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    upload_id = start_upload(admin_client, item, "wav").json()["upload_id"]
    expect_run_task(aws_stubs, item.pk, {"tasks": [], "failures": [{"reason": "RESOURCE:CPU"}]})
    body = finish(admin_client, item, upload_id).json()
    assert body["etat"] == "echec" and "n'a pas pu démarrer" in body["detail"]


@pytest.mark.django_db
def test_media_task_error_is_a_failure(admin_client, aws_stubs):
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    upload_id = start_upload(admin_client, item, "wav").json()["upload_id"]
    aws_stubs("ecs").add_client_error("run_task", service_error_code="AccessDeniedException")
    body = finish(admin_client, item, upload_id).json()
    assert body["etat"] == "echec"


@pytest.mark.django_db
def test_without_a_media_task_outside_debug_processing_fails_clearly(admin_client, settings):
    settings.MEDIA_TASK_CLUSTER = ""
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    upload_id = start_upload(admin_client, item, "wav").json()["upload_id"]
    body = finish(admin_client, item, upload_id).json()
    assert body == {"etat": "echec", "detail": "Le traitement n'est pas configuré sur ce serveur."}


@pytest.mark.django_db
def test_a_stuck_processing_is_shown_as_failed(admin_client, settings):
    item = PublishedItem.objects.create(
        kind="son",
        item_id="essai",
        nom="Essai",
        state=State.TRAITEMENT,
        upload_id=uuid.uuid4(),
        processing_started_at=timezone.now() - timedelta(hours=1),
    )
    body = admin_client.get(f"/tableau/elements/{item.pk}/etat").json()
    assert body["etat"] == "echec" and "délai" in body["detail"]


def processing_elsewhere(**fields):
    defaults = {
        "kind": "son",
        "item_id": "autre-son",
        "nom": "Autre",
        "state": State.TRAITEMENT,
        "upload_id": uuid.uuid4(),
        "processing_started_at": timezone.now(),
    }
    defaults.update(fields)
    return PublishedItem.objects.create(**defaults)


@pytest.mark.django_db
def test_no_upload_starts_while_a_media_task_runs(admin_client):
    processing_elsewhere()
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    response = start_upload(admin_client, item, "wav")
    assert response.status_code == 409
    assert response.json() == {"error": "busy", "detail": services.BUSY_DETAIL}
    item.refresh_from_db()
    assert item.state == State.BROUILLON and item.upload_id is None


@pytest.mark.django_db
def test_one_media_task_at_a_time(admin_client, aws_stubs):
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    upload_id = start_upload(admin_client, item, "wav").json()["upload_id"]
    # Another administrator's file started processing during this upload.
    other = processing_elsewhere()
    response = finish(admin_client, item, upload_id)
    assert response.status_code == 409
    assert response.json()["error"] == "busy"
    item.refresh_from_db()
    assert item.state == State.ENVOI  # the source waits; no task was started
    page = admin_client.get(f"/tableau/elements/{item.pk}").content.decode()
    assert f'id="lancer" data-upload="{upload_id}"' in page
    # Once the other one is done, the launch goes through (one RunTask, stubbed).
    PublishedItem.objects.filter(pk=other.pk).update(state=State.PRET)
    expect_run_task(aws_stubs, item.pk)
    response = finish(admin_client, item, upload_id)
    assert response.status_code == 200 and response.json()["etat"] == "traitement"


@pytest.mark.django_db
def test_a_stuck_processing_does_not_block_others(admin_client, aws_stubs):
    processing_elsewhere(processing_started_at=timezone.now() - timedelta(hours=2))
    item = PublishedItem.objects.create(kind="son", item_id="essai", nom="Essai")
    upload_id = start_upload(admin_client, item, "wav").json()["upload_id"]
    expect_run_task(aws_stubs, item.pk)
    assert finish(admin_client, item, upload_id).json()["etat"] == "traitement"


@pytest.mark.django_db
def test_publish_withdraw_replace_and_republish(admin_client, admin_account, aws_stubs, api):
    create(admin_client)
    item = PublishedItem.objects.get()
    # Nothing to publish before the files are processed.
    response = admin_client.post(f"/tableau/elements/{item.pk}/publier")
    assert response["Location"].endswith("?message=refus")
    upload_id = start_upload(admin_client, item).json()["upload_id"]
    expect_run_task(aws_stubs, item.pk)
    finish(admin_client, item, upload_id)
    processed(item)
    page = admin_client.get(f"/tableau/elements/{item.pk}").content.decode()
    assert "Aperçu — fichiers v1 (à publier)" in page and "Publier" in page
    assert "videos/paysages/lac-brume.v1.mp4?Expires=" not in page  # signing not configured
    assert "Aperçu indisponible" in page

    response = admin_client.post(f"/tableau/elements/{item.pk}/publier")
    assert response["Location"].endswith("?message=publie")
    item.refresh_from_db()
    assert (item.state, item.en_catalogue, item.media_rev) == (State.PUBLIE, True, 1)
    assert item.has_ambiance
    catalog = api.get("/v1/catalog").json()
    assert catalog["revision"] == 1
    assert catalog["catalog"]["paysages"][-1]["media_rev"] == 1

    # Replace the file: the element stays online with its current files meanwhile.
    upload_id = start_upload(admin_client, item).json()["upload_id"]
    item.refresh_from_db()
    assert item.pending_rev == 2 and item.media_rev == 1 and item.en_catalogue
    assert AdminLogEntry.objects.filter(action="remplacement").count() == 1
    assert api.get("/v1/catalog").json()["revision"] == 1
    expect_run_task(aws_stubs, item.pk)
    finish(admin_client, item, upload_id)
    processed(item, ambiance=False)
    admin_client.post(f"/tableau/elements/{item.pk}/publier")
    item.refresh_from_db()
    assert (item.media_rev, item.has_ambiance) == (2, False)
    body = api.get("/v1/catalog").json()
    assert body["revision"] == 2
    assert body["catalog"]["paysages"][-1]["media_rev"] == 2
    assert not any(s["id"] == "ambiance-lac-brume" for s in body["catalog"]["sons"])

    response = admin_client.post(f"/tableau/elements/{item.pk}/retirer")
    assert response["Location"].endswith("?message=retire")
    item.refresh_from_db()
    assert (item.state, item.en_catalogue) == (State.RETIRE, False)
    assert api.get("/v1/catalog").json()["revision"] == 3
    assert admin_client.post(f"/tableau/elements/{item.pk}/retirer")["Location"].endswith("refus")
    # Withdrawn: its files stay and it can be published again.
    admin_client.post(f"/tableau/elements/{item.pk}/publier")
    item.refresh_from_db()
    assert (item.state, item.en_catalogue, item.media_rev) == (State.PUBLIE, True, 2)
    assert published_catalog().revision == 4
    actions = list(AdminLogEntry.objects.order_by("at", "id").values_list("action", flat=True))
    assert actions == [
        "creation",
        "envoi",
        "publication",
        "remplacement",
        "publication",
        "retrait",
        "publication",
    ]


@pytest.mark.django_db
def test_preview_uses_signed_cdn_addresses(admin_client, settings):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    settings.CLOUDFRONT_PRIVATE_KEY = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    item = PublishedItem.objects.create(
        kind="paysage",
        item_id="lac-brume",
        nom="Lac",
        theme="nature",
        state=State.PRET,
        pending_rev=3,
        pending_has_ambiance=True,
    )
    html = admin_client.get(f"/tableau/elements/{item.pk}").content.decode()
    for key_path in (
        "videos/paysages/lac-brume.v3.mp4",
        "images/paysages/lac-brume.v3.jpg",
        "audio/sons/ambiance-lac-brume.v3.ogg",
    ):
        assert f"https://cdn.eventide.test/{key_path}?Expires=" in html


@pytest.mark.django_db
def test_edit_name_aliases_and_access(admin_client):
    item = PublishedItem.objects.create(kind="son", item_id="vent-doux", nom="Vent doux")
    page = admin_client.get(f"/tableau/elements/{item.pk}/modifier")
    assert page.status_code == 200 and 'value="Vent doux"' in page.content.decode()
    response = admin_client.post(
        f"/tableau/elements/{item.pk}/modifier",
        {"nom": "Brise", "gratuit": "gratuit", "alias": "brise, Vent Léger"},
    )
    assert response["Location"].endswith("?message=modifie")
    item.refresh_from_db()
    assert (item.nom, item.gratuit, item.alias) == ("Brise", True, ["brise", "vent léger"])
    # Not online: the catalog revision does not move.
    assert published_catalog().revision == 0
    assert AdminLogEntry.objects.filter(action="modification").count() == 1
    bad = admin_client.post(f"/tableau/elements/{item.pk}/modifier", {"nom": "B", "gratuit": "x"})
    assert bad.status_code == 400


@pytest.mark.django_db
def test_unknown_element_is_404(admin_client):
    response = admin_client.get(f"/tableau/elements/{uuid.uuid4()}")
    assert response.status_code == 404


@pytest.mark.django_db
def test_catalogue_page_lists_elements(admin_client):
    PublishedItem.objects.create(kind="musique", item_id="piano-nuit", nom="Piano de nuit")
    html = admin_client.get("/tableau/").content.decode()
    assert "Piano de nuit" in html and "piano-nuit" in html and "Brouillon" in html
    assert "Révision du catalogue publié : <strong>0</strong>" in html


@pytest.mark.django_db
def test_users_page_totals_and_rows(admin_client, django_assert_max_num_queries):
    now = timezone.now()
    linked = Account.objects.create(google_sub="user-1")
    old, _ = make_installation()
    recent, _ = make_installation(account=linked)
    today, _ = make_installation()
    make_installation(account=linked)
    Installation.objects.filter(pk=old.pk).update(last_seen_at=now - timedelta(days=40))
    Installation.objects.filter(pk=recent.pk).update(last_seen_at=now - timedelta(days=10))
    make_purchase(account=linked, base_plan_id="annual")
    make_purchase(installation=today)  # monthly
    make_purchase(
        installation=old, kind="lifetime", product_id="eventide_lifetime", base_plan_id=""
    )
    make_purchase(installation=old, state="expired", expires_at=now - timedelta(days=50))
    Share.objects.create(code="Aa11Bb22", scene={}, installation=today)
    Share.objects.create(code="Cc33Dd44", scene={}, installation=today)
    with django_assert_max_num_queries(9):
        response = admin_client.get("/tableau/utilisateurs")
    assert response.status_code == 200
    totals = response.context["totals"]
    assert (totals.installations, totals.actives_7, totals.actives_30, totals.comptes) == (
        4,
        2,
        3,
        1,
    )
    assert dict(totals.premium) == {
        "Abonnement annuel": 1,
        "Abonnement mensuel": 1,
        "À vie": 1,
    }
    rows = {r["installation"]: r for r in response.context["rows"]}
    assert rows[str(today.pk)[:8]]["partages"] == 2
    assert rows[str(today.pk)[:8]]["premium"]["produit"] == "Abonnement mensuel"
    assert rows[str(recent.pk)[:8]]["compte"] is True
    assert rows[str(recent.pk)[:8]]["premium"]["produit"] == "Abonnement annuel"
    assert rows[str(old.pk)[:8]]["premium"]["produit"] == "À vie"
    html = response.content.decode()
    assert str(today.pk)[:8] in html and str(today.pk) not in html
    assert today.device_hash not in html


@pytest.mark.django_db
def test_users_page_is_paginated_by_50(admin_client):
    for _ in range(51):
        make_installation()
    first = admin_client.get("/tableau/utilisateurs")
    assert len(first.context["rows"]) == 50
    assert first.context["pagination"]["next"] == 2
    second = admin_client.get("/tableau/utilisateurs?page=2")
    assert len(second.context["rows"]) == 1
    assert admin_client.get("/tableau/utilisateurs?page=x").status_code == 200


@pytest.mark.django_db
def test_journal_page(admin_client, admin_account):
    item = PublishedItem.objects.create(kind="son", item_id="vent-doux", nom="Vent doux")
    AdminLogEntry.objects.create(account=admin_account, action="publication", element=item)
    AdminLogEntry.objects.create(account=None, action="connexion")
    html = admin_client.get("/tableau/journal").content.decode()
    assert "Publication" in html and "(vous)" in html and "compte supprimé" in html
    assert f"/tableau/elements/{item.pk}" in html


@pytest.mark.django_db
def test_purge_removes_old_journal_entries_and_expired_sessions(admin_account):
    AdminLogEntry.objects.create(account=admin_account, action="connexion")
    AdminLogEntry.objects.create(
        account=admin_account, action="connexion", at=timezone.now() - timedelta(days=366)
    )
    expired = SessionStore()
    expired["x"] = 1
    expired.set_expiry(-10)
    expired.save()
    live = SessionStore()
    live["x"] = 1
    live.save()
    out = StringIO()
    call_command("purge_expired", stdout=out)
    summary = json.loads(out.getvalue())
    assert summary["admin_log_entries"] == 1 and summary["sessions"] == 1
    assert AdminLogEntry.objects.count() == 1


@pytest.mark.django_db
def test_privacy_page_mentions_the_dashboard(client):
    html = client.get("/confidentialite").content.decode()
    assert "tableau de bord" in html
    assert "jamais enregistrée" in html


@pytest.mark.django_db
def test_dashboard_pages_read_few_rows(admin_client):
    item = PublishedItem.objects.create(kind="son", item_id="vent-doux", nom="Vent doux")
    with CaptureQueriesContext(connection) as queries:
        admin_client.get(f"/tableau/elements/{item.pk}/etat")
    # The session, the administrator's account, the element.
    assert len(queries) == 3
