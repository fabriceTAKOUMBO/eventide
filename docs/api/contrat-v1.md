# Contrat d'API v1 — Eventide

Contrat partagé entre l'application Flutter (`app/`) et l'API Django (`backend/`). **Une forme qui change s'écrit ici avant le code.**

- Base : `https://api.<domaine>/v1/` (domaine à confirmer : vérification de marque « Eventide », annexe D du dossier).
- JSON UTF-8. Enveloppe et champs techniques en anglais `snake_case`. **Le document de scène, les programmations et les opérations de l'assistant gardent les clés françaises de l'annexe A du dossier** (`paysage`, `sons`, `niveau`…), car c'est le format stocké, partagé et produit par le modèle.
- Erreurs : `{"error": "<code>", "detail": "<texte court, sans donnée personnelle>"}` avec un statut HTTP cohérent. Codes communs à toutes les routes (en plus de ceux de chaque section) : `401 unauthorized` (jeton absent, inconnu ou révoqué ; en-tête `WWW-Authenticate: Bearer`), `404 not_found`, `405 method_not_allowed`, `413 payload_too_large` (corps de plus de 64 Kio), `415 unsupported_media_type` (corps non JSON), `429 rate_limited` (avec `Retry-After` en secondes), `500 server_error`.
- Authentification : `Authorization: Bearer <token>` (jeton d'installation, § 2), sauf `GET /health`, `POST /installations`, `POST /play/rtdn` et les pages web (§ 9).
- Le catalogue fermé (paysages, sons, musiques, décors, limites) est **`app/assets/catalog.json`** : une seule source, lue par l'application et embarquée par l'API (copie vérifiée par un test des deux côtés).

## 1. Document de scène (annexe A)

```json
{
  "version": 1,
  "paysage": "cascade-foret",
  "moment": "jour",
  "sons":    [{"id": "eau-vive", "niveau": 60}, {"id": "oiseaux", "niveau": 40}],
  "musique": [{"id": "piano-doux", "niveau": 25}],
  "decor":   [{"id": "brume", "niveau": 30}],
  "minuteur": {"mode": "duree", "minutes": 60},
  "sommeil": {"suivi": true}
}
```

| Champ | Règle |
|---|---|
| `moment` | `aube`, `jour`, `soir`, `nuit` |
| `niveau` | entier 0 à 100 (volume pour un son ou une musique, intensité pour un décor). 0 retire l'élément |
| couches | `sons` + `musique` : 6 au plus (`limites.couches_max`) ; un même `id` une seule fois |
| `minuteur` | `{"mode":"duree","minutes":1..600}`, `{"mode":"nuit"}` (arrêt après `limites.nuit_max_heures`), `{"mode":"aucun"}` |

Le dossier écrit `intensite` pour un décor : on utilise `niveau` partout pour un schéma unique.

## 2. Programmation (stockée à part, jamais partagée)

```json
{"id": "a1b2", "heure": "22:00", "jours": [1,2,3,4,5,6,7], "montee_minutes": 10,
 "paysage": "cascade-foret", "rappel": "dormir", "actif": true}
```

`heure` locale `HH:MM` (24 h) ; `jours` 1 = lundi … 7 = dimanche, au moins un ; `montee_minutes` 5, 10 ou 15 à 60 par pas de 5 ; `rappel` `dormir` ou `detente`.

## 3. Opérations de l'assistant

Une réponse n'est jamais du texte libre, mais une liste d'opérations. Champs possibles : `op`, `cible`, `id`, `niveau`, `delta`, `valeur`, `selecteur`, `cle`, `raison`.

| `op` | `cible` | Autres champs | Exemple de phrase |
|---|---|---|---|
| `definir` | `paysage` | `valeur`: id de paysage | « Mets la cascade en forêt » |
| `changer` | `paysage` | `valeur`: `suivant` \| `precedent` | « Change de paysage » |
| `definir` | `moment` | `valeur`: `aube`…`nuit` | « Il fait nuit » |
| `ajouter` | `son` \| `musique` \| `decor` | `id`, `niveau` (facultatif, 50 par défaut) | « Ajoute du piano doux » |
| `retirer` | `son` \| `musique` \| `decor` | `id` (`*` = tous ceux de la cible) | « Coupe la musique » |
| `regler` | `son` \| `musique` \| `decor` | `id`, `niveau` | « Mets l'eau vive à 70 pour cent » |
| `ajuster` | `son` \| `musique` \| `decor` | `id`, `delta` (−100 à 100) | « Baisse les oiseaux » (−20) |
| `definir` | `minuteur` | `valeur`: objet minuteur (§ 1) | « Arrête dans une heure » |
| `lecture` | — | `valeur`: `pause` \| `reprise` | « Pause » |
| `creer` | `programmation` | `valeur`: programmation sans `id` ni `actif` | « Programme la pluie tous les soirs à 22 h » |
| `modifier` | `programmation` | `selecteur`, `valeur` (champs partiels) | « Décale ma programmation à 22 h 30 » |
| `activer` \| `desactiver` \| `supprimer` | `programmation` | `selecteur` | « Désactive ma programmation de 22 h » |
| `definir` | `sommeil.suivi` | `valeur`: booléen | « Active le suivi du sommeil » |
| `commencer_nuit` | — | — | « Commence la nuit » |
| `definir` | `reglage` | `cle`: `taille_texte` (`valeur` `plus` \| `moins` \| 0..2), `contraste_renforce`, `ecran_noir_minuteur`, `wifi_seulement` (`valeur` booléen) | « Mets le texte plus grand » |
| `partager` | — | — | « Partage mon mix » |
| `ouvrir` | `premium` | — | « Passe-moi en Premium » (ouvre l'écran, n'achète jamais) |
| `reformuler` | — | `raison` | phrase ambiguë ou incomprise |
| `refuser` | — | `raison`: `hors_catalogue` \| `interdit` | « Quelle heure est-il ? », « Supprime mon compte » |

`selecteur` : `{"id": "..."}`, ou `{"heure": "22:00"}`, ou `{"rappel": "dormir"}`, ou `{"moment_journee": "matin"|"apres-midi"|"soir"}` (« la programmation du matin » : heure < 12 h, 12–18 h, ≥ 18 h).

**Validation, des deux côtés** (API avant de répondre, application avant d'appliquer) : `op` et `cible` connus, `id` dans le catalogue, bornes (`niveau` 0–100, `delta` −100–100, `montee_minutes`, `heure`, `jours`), droits de la formule (un élément Premium demandé par un gratuit → l'opération est retirée et remplacée par `{"op":"ouvrir","cible":"premium"}`), jamais d'achat, d'abonnement, de résiliation ni de suppression de compte. Une opération invalide est retirée ; une liste vide devient `[{"op":"reformuler","raison":"incompris"}]`.

### 3.1 Règles de validation détaillées

Les deux validateurs (API, application) appliquent exactement ces règles, dans cet ordre. Les cas partagés **`shared/test-vectors/ops-validation.json`** (tableau de `{"name", "plan", "ops_in", "ops_out"}`, `plan` parmi `free`, `monthly`, `annual`, `lifetime`) sont joués par les tests des deux côtés : une règle nouvelle s'écrit ici et dans ce fichier avant le code.

1. **Entrée** : une liste est attendue ; toute autre valeur vaut une liste vide. Seuls les **10 premiers éléments** sont lus ; un élément qui n'est pas un objet est ignoré.
2. **Interdit** : si l'un de ces éléments demande un achat, un abonnement, une résiliation ou une suppression de compte, **toute la liste** devient `[{"op":"refuser","raison":"interdit"}]` (rien d'autre n'est appliqué). Est interdit : un `op` parmi `acheter`, `achat`, `payer`, `abonner`, `s_abonner`, `souscrire`, `resilier`, `desabonner`, `se_desabonner`, `rembourser`, `supprimer_compte` ; une `cible` parmi `compte`, `abonnement`, `achat`, `paiement`, `credits`, `facturation` ; la `cible` `premium` avec un `op` autre que `ouvrir`.
3. **Chaque opération** est contrôlée selon le tableau ci-dessus ; invalide, elle est retirée. Les types sont stricts : un `niveau`, un `delta`, des `minutes` ou des `jours` sont des **entiers JSON** (ni booléen, ni nombre décimal, ni texte) ; `valeur` booléenne = `true`/`false` JSON. Les champs inattendus sont **supprimés** sans invalider l'opération (ex. `cible` de `lecture`, `minutes` d'un minuteur `nuit`, `id` et `actif` d'une programmation à créer). Valeurs par défaut écrites dans la sortie : `niveau` 50 pour `ajouter` ; pour `creer`, `montee_minutes` 10 et `rappel` `dormir`. Précisions :
   - `creer programmation` exige `heure` et `jours` ; `paysage` est facultatif (absent = paysage en cours, choisi par l'application) ; `jours` est rendu **trié et sans doublon** ;
   - `modifier programmation` exige un `selecteur` et au moins un champ valide parmi `heure`, `jours`, `montee_minutes`, `paysage`, `rappel` ; un champ invalide invalide l'opération ;
   - `selecteur` : **une seule** clé parmi `id` (texte de 1 à 64 caractères), `heure`, `rappel`, `moment_journee` ; deux clés ou plus = invalide ;
   - `retirer` accepte `id` = `*` ; `regler` et `ajuster` exigent un `id` précis ;
   - `reformuler` : `raison` `incompris` ou `ambigu`, toute autre valeur devient `incompris` ; `refuser` : `raison` `hors_catalogue` ou `interdit`, toute autre valeur devient `hors_catalogue`.
4. **Formule gratuite** (`free`) : une opération valide qui demande un élément Premium (`gratuit: false` dans le catalogue) est **remplacée à sa place** par `{"op":"ouvrir","cible":"premium"}`. Concernées : `definir paysage`, `ajouter`, `regler`, `ajuster`, et `creer` / `modifier programmation` avec un `paysage` Premium. Non concernées : `retirer` (toujours permis) et `changer paysage` (l'application gère les paysages verrouillés). Une opération à la fois invalide et Premium est **retirée** (l'invalide l'emporte). `monthly`, `annual` et `lifetime` ont accès à tout le catalogue.
5. **Doublons** : une opération strictement identique à une précédente (après normalisation) est retirée ; l'ordre est conservé. Il reste donc au plus un `{"op":"ouvrir","cible":"premium"}`.
6. **Liste vide** : elle devient `[{"op":"reformuler","raison":"incompris"}]` ; la sortie n'est jamais vide.

Limites qui dépendent de l'état du téléphone (6 couches au plus, un même `id` une fois dans une couche, 1 programmation en gratuit, 3 favoris en gratuit) : **appliquées par l'application au moment d'appliquer**, pas par le validateur (l'API ne connaît pas l'état exact).

## 4. Installations

`POST /installations` — sans jeton.

```json
{"integrity_token": "<jeton Play Integrity>", "request_hash": "<base64url SHA-256 du nonce>",
 "device_hash": "<hex SHA-256(ANDROID_ID + sel de l'app)>", "app_version": "1.0.0"}
```

→ `201 {"installation_id": "uuid", "token": "<opaque, 43 car.>"}`. L'API vérifie le jeton Play Integrity (application reconnue, appareil intègre) sauf si `PLAY_INTEGRITY_ENFORCED=false` (développement). Le jeton est stocké haché (SHA-256). Un nouvel appel du même appareil renvoie un nouveau jeton et révoque l'ancien. Le compteur d'essai est rattaché à `device_hash` (une réinstallation ne redonne pas trois essais), puis au compte Google s'il est lié. Erreurs : `400 invalid_request`, `403 integrity_failed`, `429 rate_limited`, `503 integrity_unavailable` (Google injoignable : réessayer plus tard).

Précisions (API) :
- formats : `device_hash` 64 caractères hexadécimaux minuscules ; `request_hash` 43 caractères base64url sans `=` ; `app_version` `X.Y.Z` (suffixe `-…` ou `+…` permis) ;
- une seule installation par `device_hash` : un nouvel appel garde le même `installation_id` (et son compte lié, ses compteurs), seul le jeton change ;
- verdict accepté (API standard, `decodeIntegrityToken`) : `requestDetails.requestPackageName` = paquet de l'application, `requestDetails.requestHash` = `request_hash` reçu, horodatage de moins de 5 minutes, `appIntegrity.appRecognitionVerdict` = `PLAY_RECOGNIZED`, `deviceIntegrity.deviceRecognitionVerdict` contient `MEETS_DEVICE_INTEGRITY` (réglable) ;
- limites : 20 appels par heure par adresse IP, 10 par jour par appareil.

## 5. Compte (facultatif)

- `POST /account/google` `{"id_token": "<jeton d'identité Google>"}` → `200 {"account_id": "uuid", "linked": true}`. Lie l'installation au compte Google (`sub`) ; droits et compteurs suivent alors le compte. `401 invalid_google_token`, `503 google_unavailable` (certificats de Google injoignables). Le jeton est vérifié côté serveur (signature, émetteur, expiration, audience = un des identifiants clients configurés) ; seul `sub` est conservé (ni e-mail, ni nom). À la liaison : les achats de l'installation passent au compte, ses crédits s'ajoutent à ceux du compte, le coût vocal du mois s'ajoute à celui du compte, et les deux compteurs d'essai prennent la plus grande des deux valeurs (lier un compte ne redonne pas d'essai). 10 liaisons par heure par installation.
- `GET /account/export` → toutes les données tenues par le serveur pour ce compte ou cette installation (RGPD) : installations (dont `device_hash`), compte (`google_sub`), achats, coût vocal mensuel, détail des demandes vocales (date, origine, coût ; jamais la phrase), partages créés. Le jeton n'y figure pas. 10 exports par heure.
- `DELETE /account` → `204` ; supprime installation, compte, partages créés, compteurs (les achats restent chez Google Play). Si l'installation est liée, **toutes les installations liées au compte** sont supprimées avec lui (leurs jetons cessent de fonctionner). Un achat toujours actif chez Google Play peut être de nouveau envoyé par `POST /purchases` (« Restaurer mes achats »).

## 6. Droits et achats

`GET /entitlements` →

```json
{"plan": "free", "premium": false, "expires_at": null, "auto_renewing": false,
 "voice": {"mode": "trial", "trial_remaining": 3, "credits_remaining": 0, "monthly_cap_reached": false}}
```

`plan` : `free`, `monthly`, `annual`, `lifetime`. `voice.mode` : `trial` (gratuit), `included` (mensuel, annuel), `credits` (à vie), `none` (assistant coupé côté serveur, `VOICE_ENABLED=false`).

Précisions : un abonnement en cours (actif, annulé mais pas encore échu, ou en délai de grâce) l'emporte sur l'achat à vie ; `expires_at` (ISO 8601 UTC, `Z`) est la fin de la période payée. `trial_remaining` et `credits_remaining` sont toujours les valeurs réelles, quelle que soit la formule. `monthly_cap_reached` n'est vrai qu'en mode `included`. Propriétaire des droits : le compte s'il est lié, sinon l'installation.

`POST /purchases` `{"product_id": "eventide_premium" | "eventide_lifetime" | "eventide_credits_50", "purchase_token": "...", "base_plan_id": "monthly" | "annual" | null}` → `200` + même corps que `/entitlements`. L'API vérifie l'achat auprès de l'API Google Play Developer, l'**acquitte** (ou consomme les crédits) dans les 3 jours, l'enregistre ; idempotent sur `purchase_token`. Erreurs : `400 invalid_request`, `402 purchase_invalid`, `409 purchase_owned_by_other_account`, `503 play_unavailable` (Google injoignable : réessayer).

Précisions :
- `base_plan_id` : `monthly`, `annual` ou `null` pour `eventide_premium` (l'offre réellement achetée est lue chez Google et l'emporte), `null` pour les deux autres produits ;
- `409` : le jeton appartient déjà à une **autre installation non liée** ou à un **autre compte** ; l'application propose alors de lier le compte Google ;
- achat en attente de paiement : `200` sans changement de droits ; il prend effet par la notification temps réel quand Google le confirme ;
- achat remboursé, annulé ou expiré : `402 purchase_invalid` ;
- crédits : 50 par unité achetée (`quantity` de Google), **accordés une seule fois** par jeton, puis le jeton est consommé ; un remboursement reprend ce qui reste des crédits accordés (jamais en dessous de zéro) ;
- l'application envoie aussi, à son démarrage, ses achats actifs (renouvellements manqués) ; 30 appels par heure par installation.

`POST /play/rtdn` — notifications en temps réel de Google Play (abonnement Pub/Sub push, jeton OIDC de Pub/Sub vérifié : audience et compte de service attendus) : renouvellements, annulations, suspensions, remboursements. `204`. La notification ne sert que de signal : l'état est toujours relu chez Google. Jeton absent ou invalide : `401` ; message illisible : `400 invalid_request` ; Google injoignable pendant la relecture : `503 play_unavailable` (Pub/Sub renvoie le message) ; jeton d'achat inconnu, autre paquet, notification de test : `204` sans effet.

Produits Google Play : abonnement `eventide_premium` (offres de base `monthly` 7,99 € et `annual` 59,99 € avec essai de 3 jours), achat unique `eventide_lifetime` (79,99 €), consommable `eventide_credits_50` (prix à fixer, 2 à 3 fois le coût).

## 7. Assistant vocal

`POST /voice`

```json
{"phrase": "mets la pluie à septante pour cent",
 "phrase_normalisee": "mets la pluie à 70 pour cent",
 "etat": {"scene": {"...": "§ 1"}, "programmations": [{"...": "§ 2"}], "lecture": "en_cours",
          "reglages": {"taille_texte": 0, "contraste_renforce": false, "ecran_noir_minuteur": true, "wifi_seulement": false}},
 "actions_locales": null}
```

- `actions_locales` non nul : la phrase a été résolue sur le téléphone par les règles ; l'API **ne fait que compter** la demande (essai gratuit, crédits), valide la liste et la renvoie avec `source: "local"`. Pour un abonné (mensuel, annuel), l'application n'appelle pas l'API dans ce cas.
- Sinon, l'API réserve le quota (écriture conditionnelle atomique dans PostgreSQL), appelle le modèle (famille Gemini Flash-Lite, modèle choisi par configuration, sortie JSON stricte selon un schéma), valide (§ 3), enregistre le coût réel (jetons × tarif) et répond.

→ `200 {"actions": [ ... ], "source": "model" | "local", "voice": { ...comme /entitlements } }`

| Statut | `error` | L'application fait |
|---|---|---|
| 402 | `voice_quota_exhausted` (essais épuisés, crédits à 0, ou à vie sans crédit) | ouvre Premium (ou l'achat de crédits pour l'à-vie) |
| 402 | `voice_monthly_cap` (plafond de 2 € du mois atteint pour un abonné) | règles seules jusqu'au mois suivant, sans couper l'assistant |
| 422 | `invalid_request` | message « Je n'ai pas compris » |
| 503 | `model_unavailable` | règles seules ; la réservation est rendue |

Règles côté API : la phrase et la transcription ne sont **jamais** journalisées ni stockées ; 20 demandes par minute et 300 par jour au plus par installation ; plafond de 2 € par mois et par abonné tenu en coût réel (`VOICE_MONTHLY_CAP_EUR`, `USD_EUR_RATE`) ; la réservation est rendue si le modèle échoue.

Précisions :
- **ordre de consommation**, formule gratuite et achat à vie : essais restants d'abord, puis crédits ; l'essai est compté à la fois sur l'appareil et, s'il est lié, sur le compte (3 au total, réservation atomique) ;
- un abonné qui envoie quand même `actions_locales` reçoit la liste validée, sans que rien ne soit compté ;
- la réservation est faite et validée en base **avant** l'appel au modèle ; elle est rendue si l'appel échoue (réseau, délai, erreur HTTP : `503 model_unavailable`) ; une réponse `200` du modèle compte, même si elle ne donne aucune action valide (la liste devient alors `reformuler`) ;
- au-delà d'un plafond quotidien global de coût (tous utilisateurs, `VOICE_GLOBAL_DAILY_CAP_EUR`), l'API répond `503 model_unavailable` sans rien compter ; `VOICE_ENABLED=false` : `503 model_unavailable` pour le modèle, `actions_locales` validées sans comptage ;
- `422 invalid_request` : `phrase` (et `phrase_normalisee`, qui la remplace pour le modèle) vide ou de plus de 500 caractères, `etat` qui n'est pas un objet ou dépasse 32 Kio, `actions_locales` qui n'est ni `null` ni une liste de 50 éléments au plus ;
- `source` vaut `model` pour toute réponse calculée par le serveur, y compris par ses règles (`VOICE_ROUTER=rules-only`) ; coût du mois tenu par mois civil UTC.

## 8. Partage et contenu

- `POST /shares` `{"scene": { ...§ 1 }}` → `201 {"code": "k7Fq2xPa", "url": "https://<domaine>/m/k7Fq2xPa"}` (8 caractères base62, scène validée, aucune donnée personnelle, 20 partages par jour par installation). `GET /shares/{code}` → `200 {"scene": {...}}` ou `404 not_found`. La scène enregistrée ne garde que le mix : `version`, `paysage`, `moment`, `sons`, `musique`, `decor` (`minuteur`, `sommeil` et tout champ inconnu sont retirés ; un élément à `niveau` 0 est retiré). Scène invalide (§ 1 : version, identifiants, bornes, doublon dans une couche, plus de 6 couches) : `400 invalid_request`. Les éléments Premium sont gardés (le destinataire gratuit les voit verrouillés).
- L'application sait aussi produire un lien **autonome** sans serveur : `https://<domaine>/s#<base64url(JSON compact de la scène)>` ; il sert de repli hors ligne.
- `POST /content/urls` `{"keys": ["audio/sons/vagues.ogg", "images/paysages/aurore-boreale.jpg"]}` → `200 {"urls": {"<clé>": "<URL CloudFront signée>"}, "expires_at": "..."}`. Clés de contenu Premium : formule Premium exigée (`403 premium_required`). Disposition : `audio/sons/<id>.ogg`, `audio/musiques/<id>.ogg`, `images/paysages/<id>.jpg`. De 1 à 30 clés distinctes, toutes du catalogue (sinon `400 invalid_request`) ; une seule clé Premium pour un gratuit refuse toute la demande ; adresses valables 1 heure (`expires_at`, ISO 8601 UTC) ; `503 content_unavailable` si la signature n'est pas configurée ; 120 demandes par heure par installation.

## 9. Pages web servies par l'API (hôte du domaine)

- `GET /m/<code>` et `GET /s` : page de partage. Si l'application est installée, le lien vérifié (App Links) l'ouvre directement ; sinon la page montre la scène et un bouton Google Play.
- `GET /.well-known/assetlinks.json` : empreinte du certificat de signature (configuration).
- `GET /confidentialite` : politique de confidentialité.

## 10. Divers

`GET /health` → `200 {"status": "ok"}` (sans base de données ; `GET /health/ready` la vérifie : `503 {"status": "unavailable"}` sinon). Chemins complets : `/v1/health` et `/v1/health/ready` (contrôle de santé de l'ALB).
