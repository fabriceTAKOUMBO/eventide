# Contrat d'API v1 — Eventide

Contrat partagé entre l'application Flutter (`app/`) et l'API Django (`backend/`). **Une forme qui change s'écrit ici avant le code.**

- Base : `https://api.<domaine>/v1/` (domaine à confirmer : vérification de marque « Eventide », annexe D du dossier).
- JSON UTF-8. Enveloppe et champs techniques en anglais `snake_case`. **Le document de scène et les programmations gardent les clés françaises de l'annexe A du dossier** (`paysage`, `sons`, `niveau`…), car c'est le format stocké et partagé.
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
  "sourdine": {"sons": false, "musique": false},
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
| `sourdine` | `{"sons": booléen, "musique": booléen}` : catégorie coupée **sans perdre ses couches ni leurs niveaux** (remettre le son rend le mix exact d'un seul geste). Facultatif à la lecture : absent, ou une clé absente ou non booléenne, vaut `false`. Le décor n'a pas de sourdine |

Le dossier écrit `intensite` pour un décor : on utilise `niveau` partout pour un schéma unique.

`sourdine` est un ajout facultatif : la `version` reste **1** (un document sans `sourdine` reste valide et se lit « rien en sourdine » ; aucune autre forme ne change). Sens dans l'application :
- une couche d'une catégorie en sourdine reste dans la scène avec son niveau ; seul ce qu'on entend change (volume 0, fondu d'environ 1 s à la coupure comme au retour) ;
- la sourdine est un état d'écoute, comme le minuteur : elle est **gardée** quand le mix change (paysage, favori, programmation) et enregistrée avec la scène ; un favori et un partage ne la portent pas, et l'ouverture d'un lien de partage la retire (le destinataire entend le mix partagé, § 8) ;
- un **démarrage** (lecture depuis l'arrêt, démarrage programmé) où tout ce qui est dans le mix serait en sourdine remet les deux catégories : un démarrage n'est jamais muet. Une **reprise** après une pause garde la sourdine ;
- toucher au niveau d'un élément d'une catégorie en sourdine (curseur, − / +, ajout) la remet, si l'élément reste dans le mix. Retirer un élément ne change pas la sourdine.

## 2. Programmation (stockée à part, jamais partagée)

```json
{"id": "a1b2", "heure": "22:00", "jours": [1,2,3,4,5,6,7], "montee_minutes": 10,
 "paysage": "cascade-foret", "rappel": "dormir", "actif": true}
```

`heure` locale `HH:MM` (24 h) ; `jours` 1 = lundi … 7 = dimanche, au moins un ; `montee_minutes` 5, 10 ou 15 à 60 par pas de 5 ; `rappel` `dormir` ou `detente`.

## 3. Opérations de l'assistant — retirées

**Retirées le 29 octobre 2026** (décision du product owner : plus de micro ni d'assistant vocal). Les opérations (`definir`, `ajouter`, `regler`…), leurs règles de validation et les vecteurs partagés `shared/test-vectors/ops-validation.json` ne font plus partie du contrat. Le code reste dans l'historique git (avant ce retrait) pour une éventuelle phase 2.

## 4. Installations

`POST /installations` — sans jeton.

```json
{"integrity_token": "<jeton Play Integrity>", "request_hash": "<base64url SHA-256 du nonce>",
 "device_hash": "<hex SHA-256(ANDROID_ID + sel de l'app)>", "app_version": "1.0.0"}
```

→ `201 {"installation_id": "uuid", "token": "<opaque, 43 car.>"}`. L'API vérifie le jeton Play Integrity (application reconnue, appareil intègre) sauf si `PLAY_INTEGRITY_ENFORCED=false` (développement). Le jeton est stocké haché (SHA-256). Un nouvel appel du même appareil renvoie un nouveau jeton et révoque l'ancien. Erreurs : `400 invalid_request`, `403 integrity_failed`, `429 rate_limited`, `503 integrity_unavailable` (Google injoignable : réessayer plus tard).

Précisions (API) :
- formats : `device_hash` 64 caractères hexadécimaux minuscules ; `request_hash` 43 caractères base64url sans `=` ; `app_version` `X.Y.Z` (suffixe `-…` ou `+…` permis) ; `integrity_token` chaîne de 8 192 caractères au plus, vide si Play Integrity n'est pas disponible sur l'appareil (version de débogage, APK installé hors Play) : un jeton vide n'est accepté qu'avec `PLAY_INTEGRITY_ENFORCED=false`, sinon `403 integrity_failed` ;
- une seule installation par `device_hash` : un nouvel appel garde le même `installation_id` (et son compte lié), seul le jeton change ;
- verdict accepté (API standard, `decodeIntegrityToken`) : `requestDetails.requestPackageName` = paquet de l'application, `requestDetails.requestHash` = `request_hash` reçu, horodatage de moins de 5 minutes, `appIntegrity.appRecognitionVerdict` = `PLAY_RECOGNIZED`, `deviceIntegrity.deviceRecognitionVerdict` contient `MEETS_DEVICE_INTEGRITY` (réglable) ;
- limites : 20 appels par heure par adresse IP, 10 par jour par appareil.

## 5. Compte (facultatif)

- `POST /account/google` `{"id_token": "<jeton d'identité Google>"}` → `200 {"account_id": "uuid", "linked": true}`. Lie l'installation au compte Google (`sub`) ; les droits suivent alors le compte. `401 invalid_google_token`, `503 google_unavailable` (certificats de Google injoignables). Le jeton est vérifié côté serveur (signature, émetteur, expiration, audience = un des identifiants clients configurés) ; seul `sub` est conservé (ni e-mail, ni nom). À la liaison : les achats de l'installation passent au compte. 10 liaisons par heure par installation.
- `GET /account/export` → toutes les données tenues par le serveur pour ce compte ou cette installation (RGPD) : installations (dont `device_hash`), compte (`google_sub`), achats, partages créés. Le jeton n'y figure pas. 10 exports par heure.
- `DELETE /account` → `204` ; supprime installation, compte, partages créés (les achats restent chez Google Play). Si l'installation est liée, **toutes les installations liées au compte** sont supprimées avec lui (leurs jetons cessent de fonctionner). Un achat toujours actif chez Google Play peut être de nouveau envoyé par `POST /purchases` (« Restaurer mes achats »).

## 6. Droits et achats

`GET /entitlements` →

```json
{"plan": "free", "premium": false, "expires_at": null, "auto_renewing": false}
```

`plan` : `free`, `monthly`, `annual`, `lifetime`.

Précisions : un abonnement en cours (actif, annulé mais pas encore échu, ou en délai de grâce) l'emporte sur l'achat à vie ; `expires_at` (ISO 8601 UTC, `Z`) est la fin de la période payée. Propriétaire des droits : le compte s'il est lié, sinon l'installation.

`POST /purchases` `{"product_id": "eventide_premium" | "eventide_lifetime", "purchase_token": "...", "base_plan_id": "monthly" | "annual" | null}` → `200` + même corps que `/entitlements`. L'API vérifie l'achat auprès de l'API Google Play Developer, l'**acquitte** dans les 3 jours, l'enregistre ; idempotent sur `purchase_token`. Erreurs : `400 invalid_request`, `402 purchase_invalid`, `409 purchase_owned_by_other_account`, `503 play_unavailable` (Google injoignable : réessayer).

Précisions :
- `base_plan_id` : `monthly`, `annual` ou `null` pour `eventide_premium` (l'offre réellement achetée est lue chez Google et l'emporte), `null` pour `eventide_lifetime` ;
- `409` : le jeton appartient déjà à une **autre installation non liée** ou à un **autre compte** ; l'application propose alors de lier le compte Google ;
- achat en attente de paiement : `200` sans changement de droits ; il prend effet par la notification temps réel quand Google le confirme ;
- achat remboursé, annulé ou expiré : `402 purchase_invalid` ;
- l'application envoie aussi, à son démarrage, ses achats actifs (renouvellements manqués) ; 30 appels par heure par installation.

`POST /play/rtdn` — notifications en temps réel de Google Play (abonnement Pub/Sub push, jeton OIDC de Pub/Sub vérifié : audience et compte de service attendus) : renouvellements, annulations, suspensions, remboursements. `204`. La notification ne sert que de signal : l'état est toujours relu chez Google. Jeton absent ou invalide : `401` ; message illisible : `400 invalid_request` ; Google injoignable pendant la relecture : `503 play_unavailable` (Pub/Sub renvoie le message) ; jeton d'achat inconnu, autre paquet, notification de test : `204` sans effet.

Produits Google Play : abonnement `eventide_premium` (offres de base `monthly` 7,99 € et `annual` 59,99 € avec essai de 3 jours), achat unique `eventide_lifetime` (79,99 €). Plus de pack de crédits (assistant retiré).

## 7. Assistant vocal — retiré

**Retiré le 29 octobre 2026** : plus de `POST /voice`, plus d'appel à un modèle (Gemini), plus de quota, d'essai, de crédits ni de plafond de coût. L'application ne demande plus la permission du micro.

## 8. Partage et contenu

- `POST /shares` `{"scene": { ...§ 1 }}` → `201 {"code": "k7Fq2xPa", "url": "https://<domaine>/m/k7Fq2xPa"}` (8 caractères base62, scène validée, aucune donnée personnelle, 20 partages par jour par installation). `GET /shares/{code}` → `200 {"scene": {...}}` ou `404 not_found`. La scène enregistrée ne garde que le mix : `version`, `paysage`, `moment`, `sons`, `musique`, `decor` (`minuteur`, `sommeil`, `sourdine` et tout champ inconnu sont retirés, quelle que soit leur forme ; un élément à `niveau` 0 est retiré). **La sourdine n'est jamais partagée** : le destinataire reçoit le mix tel qu'on l'entend sans sourdine, toutes couches audibles. Scène invalide (§ 1 : version, identifiants, bornes, doublon dans une couche, plus de 6 couches) : `400 invalid_request`. Les éléments Premium sont gardés (le destinataire gratuit les voit verrouillés).
- L'application sait aussi produire un lien **autonome** sans serveur : `https://<domaine>/s#<base64url(JSON compact de la scène)>` ; il sert de repli hors ligne. Il porte les mêmes champs que la scène enregistrée par le serveur (ni `minuteur`, ni `sommeil`, ni `sourdine`).
- `POST /content/urls` `{"keys": ["audio/sons/vagues.ogg", "images/paysages/aurore.jpg", "videos/paysages/pluie-ville.mp4"]}` → `200 {"urls": {"<clé>": "<URL CloudFront signée>"}, "expires_at": "..."}`. Clés de contenu Premium : formule Premium exigée (`403 premium_required`). Disposition : `audio/sons/<id>.ogg` (`<id>` : un son du catalogue, ou une variante d'un son à événements, § 11), `audio/musiques/<id>.ogg`, `images/paysages/<id>.jpg` (image fixe du paysage : exactement la première image de sa vidéo), `videos/paysages/<id>.mp4` (vidéo du paysage : boucle sans raccord, H.264, sans son, 2,5 Mo au plus) ; `<id>` est un paysage du catalogue pour ces deux dernières. L'application ne demande que les clés listées dans `app/assets/landscapes/remote.json` (fichier généré par les outils de `tools/media/` d'après `content/` : vidéos, images, sons et musiques publiés), jamais une vidéo absente. De 1 à 30 clés distinctes, toutes du catalogue (sinon `400 invalid_request`) ; une seule clé Premium pour un gratuit refuse toute la demande ; adresses valables 1 heure (`expires_at`, ISO 8601 UTC) ; `503 content_unavailable` si la signature n'est pas configurée ; 120 demandes par heure par installation.

## 9. Pages web servies par l'API (hôte du domaine)

- `GET /m/<code>` et `GET /s` : page de partage. Si l'application est installée, le lien vérifié (App Links) l'ouvre directement ; sinon la page montre la scène et un bouton Google Play.
- `GET /.well-known/assetlinks.json` : empreinte du certificat de signature (configuration).
- `GET /confidentialite` : politique de confidentialité.

## 10. Divers

`GET /health` → `200 {"status": "ok"}` (sans base de données ; `GET /health/ready` la vérifie : `503 {"status": "unavailable"}` sinon). Chemins complets : `/v1/health` et `/v1/health/ready` (contrôle de santé de l'ALB).

## 11. Catalogue : ambiance de chaque paysage et sons à événements (orage)

Ajouts du 29 octobre 2026 au catalogue (`app/assets/catalog.json`, copie de l'API vérifiée par test). Les champs ajoutés sont facultatifs : le document de scène (§ 1) ne change pas, sa `version` reste 1.

**Ambiance d'un paysage.** Le son d'origine de la vidéo du paysage, rendu en boucle sans raccord (au moins 60 s, sans tonnerre), est un son du catalogue comme les autres, avec un champ en plus :

```json
{"id": "ambiance-pluie-ville", "nom": "Ambiance de la ville", "gratuit": false, "paysage": "pluie-ville", "alias": []}
```

- `paysage` : le son appartient à ce paysage ; l'application ne le propose dans « Mon mix » qu'avec lui. Un document de scène qui le porte avec un autre paysage reste valide (aucune règle de validation ne change).
- Le mix par défaut du paysage le met en tête. La vidéo reste **sans son** (§ 8) : l'ambiance est jouée par le mélangeur, donc la pause coupe le son et la vidéo continue.

**Son à événements.** Au lieu d'une boucle, des sons courts joués de temps en temps, jamais deux fois pareils :

```json
{"id": "tonnerre", "nom": "Tonnerre", "gratuit": false, "alias": ["tonnerre", "orage"],
 "lecture": "evenements",
 "variantes": ["tonnerre-01", "tonnerre-02", "tonnerre-03"],
 "intervalle_s": [70, 170], "premier_s": [20, 60]}
```

| Champ | Règle |
|---|---|
| `lecture` | `boucle` (valeur par défaut, champ absent) ou `evenements` |
| `variantes` | au moins 3 identifiants de fichiers `audio/sons/<variante>.ogg` (même règle gratuit/Premium que le son) |
| `intervalle_s` | `[min, max]` en secondes, `0 < min ≤ max` : écart tiré au hasard entre deux événements |
| `premier_s` | `[min, max]` : délai du premier événement après le début de l'écoute, une reprise après pause ou l'ajout du son |

Lecture d'un son à événements (application) :
- le niveau (0 à 100) règle le volume ; 0 retire le son : plus aucun événement. La sourdine des sons (§ 1) les fait taire aussi ;
- à chaque événement : une variante au hasard, **jamais une des deux dernières jouées** ; légères variations tirées au hasard (volume de −6 à 0 dB, vitesse de 0,92 à 1,08, position stéréo de −0,4 à 0,4) ; jamais deux événements en même temps ;
- aucun événement pendant une pause, pendant le fondu de fin du minuteur, ni quand l'écoute est arrêtée ; une reprise retire un nouveau `premier_s` ;
- **éclair synchronisé** : si le décor `eclairs` est dans la scène (niveau > 0) et que le paysage est visible, un éclair est dessiné, puis le tonnerre suit après 0,4 à 3,5 s (plus le délai est court, plus l'éclair est vif). Sans tonnerre dans le mix, le décor `eclairs` garde ses propres éclairs, rares (un toutes les 2 à 5 minutes) et silencieux. Les éclairs ne sont plus dans les vidéos : la vidéo d'un paysage d'orage est traitée pour les retirer, et seul le décor les dessine.

## 12. Paysages réels et paysages imaginaires (3D)

Décision du product owner (29 octobre 2026) : **le décor d'un paysage filmé ne se modifie pas** (pas de neige, d'oiseaux… ajoutés sur une vraie vidéo). Les décors deviennent propres à une catégorie **« Imaginaire »** (elle remplace « Astral »), dont les paysages sont des scènes 3D dessinées en direct par l'application (Three.js), où l'utilisateur ajoute ou retire des éléments. Champs ajoutés au catalogue (facultatifs, la `version` du document de scène reste 1) :

| Champ | Règle |
|---|---|
| `themes` | `nature`, `urbain`, `imaginaire` (`{"id": "imaginaire", "nom": "Imaginaire"}`). Le thème `astral` est retiré le 30 octobre 2026 (décision du product owner) : `ciel-etoile` passe dans `nature`. Un thème sans aucun paysage montrable par l'application est caché |
| `paysages[].rendu` | `video` (vidéo réelle avec son propre son : décor **non modifiable**) ou `3d` (scène imaginaire : décor modifiable). Absent : `video` |
| `paysages[].decors` | pour `3d` seulement : identifiants des décors que la scène sait montrer (sous-ensemble de `decors`) |
| `paysages[].eclairs` | `true` pour un paysage d'orage filmé : l'éclair est dessiné avec chaque tonnerre (§ 11), ce n'est plus un décor de l'utilisateur. Le décor `eclairs` est retiré du catalogue |
| `paysages[].periode_s` | pour `3d` : durée en secondes après laquelle la scène se répète exactement (vidéo de fond d'écran et image fixe en sont tirées) |

Règle du décor (§ 1) : la couche `decor` d'une scène n'a de sens que sur un paysage `3d`, et seulement pour les identifiants de ses `decors`. **L'application et l'API retirent sans erreur** un élément de décor qui ne s'applique pas (comme un élément à `niveau` 0) : `POST /shares` l'enlève de la scène enregistrée. C'est aussi le cas d'un identifiant de décor absent du catalogue (`eclairs`, `pluie-ecran`, envoyés par une ancienne version) ; un élément de décor mal formé (pas un objet, `id` absent ou vide, `niveau` hors de 0 à 100, doublon) reste refusé (`400 invalid_request`). `POST /shares` refuse toujours un `paysage` inconnu, y compris un paysage retiré (l'application ne l'envoie plus : elle l'a déjà remplacé).

Les anciens paysages dessinés en 2D (`sous-bois`, `berge-mousseuse`, `torrent-montagne`, `pierres-eau`, `lisiere-verte`, `cafe-nuit`, `aurore-boreale`, `lune-lac`) sont retirés : ils sont remplacés par les scènes 3D de la catégorie « Imaginaire ». Un favori, une programmation ou un lien qui nomme un paysage disparu s'ouvre sur `cascade-foret` (sons, musique et minuteur gardés).

Les scènes 3D sont embarquées dans l'application (`app/assets/imaginaire/`, hors ligne). Leur image fixe et leur vidéo de fond d'écran sont tirées de la scène elle-même (`images/paysages/<id>.jpg`, `videos/paysages/<id>.mp4`, § 8), embarquées ou téléchargées selon la règle gratuit / Premium.

