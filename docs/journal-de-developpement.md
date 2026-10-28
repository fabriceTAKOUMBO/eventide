# Journal de développement — Eventide

## 28 octobre 2026 — première construction

### Décisions du product owner
- **Flutter** plutôt que Kotlin/Compose (vérifié faisable : plugins audio, voix, achats, publicité, alarmes, liens ; analyse et tests exécutables hors Android SDK).
- **PostgreSQL** pour la base, et **intégration AWS selon les règles de Candidature Express** : compte principal `466494951409`, `us-east-1`, à côté de CINAF, JobMinutes et Candidature Express, uniquement des ajouts réversibles ([ADR](infra/hebergement-mutualise.md)).

### Choix techniques pris en conséquence (à valider)
- API **Django 5.2 + DRF** sur **ECS Fargate ARM64**, comme Candidature Express (le dossier prévoyait des fonctions Lambda « dans le langage que vous maîtrisez le mieux »).
- Pas de Cognito en v1 : l'API vérifie directement le jeton Google. Pas de Valkey : compteurs et limites dans PostgreSQL.
- Règles d'écoute de l'ALB partagé : priorités **400–409** (préproduction 420–429), à confirmer libres.
- `compileSdk = 37` (exigé par `permission_handler_android`), `targetSdk = 36`.

### État
| Partie | Vérification réelle |
|---|---|
| App Flutter (`app/`) | `flutter analyze` sans remarque, **454 tests** verts ; CI GitHub : **APK debug compilé** (Kotlin et Gradle validés) |
| Domaine Dart (`app/lib/core`) | 303 tests, sous 3 fuseaux horaires ; 82 vecteurs de validation partagés avec l'API |
| API (`backend/`) | ruff, bandit, **289 tests pytest** (94 % de couverture) sur un vrai PostgreSQL 16, `check --deploy` |
| Infra (`infra/terraform/`) | `fmt`, `validate`, `terraform test` (fournisseurs simulés) ; **aucun `plan` ni `apply` réel** |
| Contenus | 18 boucles synthétiques sans raccord (mesuré après décodage), −23 LUFS ; icône goutte |

Incident : pendant un `terraform test`, un fournisseur non simulé a tenté un appel STS `GetCallerIdentity` avec des identifiants présents dans l'environnement de travail ; AWS l'a refusé (`InvalidClientTokenId`), aucune ressource touchée. Les tests simulent désormais tous les fournisseurs et s'exécutent sans identifiants.

Les workflows `backend`, `infra` et `security` ne tournent que sur `main` et les pull requests (comme Candidature Express) : ils n'ont pas encore tourné sur GitHub.

### Questions ouvertes pour le product owner
- Nom et marque « Eventide », domaine (liens de partage, App Links, politique de confidentialité, `www` redirigé ou non).
- Identifiants à fournir : sujet OIDC GitHub, nom de paquet et empreintes de signature Play, client OAuth Google, compte de service RTDN, numéro de projet Google Cloud (Play Integrity « standard »), clé Gemini.
- Identifiants CINAF recopiés de Candidature Express (9 octobre) à reconfirmer ; leurs règles d'écoute et de groupe de sécurité sont-elles des ressources autonomes dans leur Terraform ?
- Prix du pack de crédits ; plafond IA global journalier (20 € proposé par défaut, 5 € conseillé au lancement) ; taux USD/EUR.
- Suppression du compte : elle remet aujourd'hui l'essai gratuit à zéro (contrat appliqué à la lettre) — à conserver ?
- Publicité : interstitiels à l'ouverture et à la sortie, à confronter aux règles AdMob (format « App Open » en alternative).
- Conditions de Gemini (offre payante) sur l'usage des données ; éditeur et contact de la politique de confidentialité ; données hébergées aux États-Unis.

### Prochaines étapes
1. Prototypes de risque de la phase 0 sur de vrais téléphones (Samsung A, Xiaomi, Pixel, Motorola ; Android 12 à 16) : démarrage programmé sur 14 nuits, 8 h écran éteint, reconnaissance vocale `fr_BE`.
2. Jeu de 200 phrases françaises pour comparer règles et modèles.
3. Contenus sous licence commerciale (photos, sons, musiques) pour remplacer les substituts.
4. Premier déploiement selon le [runbook](runbooks/premier-deploiement.md), chaque `apply` après relecture du plan par le product owner.
