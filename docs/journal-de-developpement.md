# Journal de développement — Eventide

## 29 octobre 2026 (après-midi) — retours du test sur le S24, réorientation

**Retours du product owner après la démo sur son Galaxy S24** :
- le son ne correspondait pas à l'image (pas de tonnerre sur la vidéo d'orage) ;
- arrêt de l'app au bout d'environ 30 minutes, **sans minuteur** ;
- fond d'écran du téléphone changé au même moment, peut-être une coïncidence : l'app n'a pas la permission de le faire ;
- toucher la carte de l'écran verrouillé n'ouvrait pas l'app ;
- le micro comprenait les paroles mais n'agissait pas.

**Décisions du product owner** :
- **Micro et assistant vocal retirés** partout : app, API, infrastructure. Les opérations, Gemini, l'essai et le pack de crédits disparaissent ([contrat § 3 et § 7](api/contrat-v1.md)) ; le code reste dans l'historique git pour une éventuelle phase 2.
- **Orage** : le tonnerre ne doit pas revenir à chaque boucle. Il tombe au hasard toutes les 2 à 5 minutes, jamais de la même façon, sur une pluie continue qui reste torrentielle ([contrat § 11](api/contrat-v1.md)).
- **Fond d'écran** : la vidéo du paysage peut devenir le fond d'écran.
- **Vidéos générées avec Higgsfield** : son serveur MCP officiel est `https://mcp.higgsfield.ai/mcp`, à ajouter comme connecteur personnalisé sur claude.ai. Il faut **une nouvelle session** pour qu'il soit chargé, et chaque génération consomme des crédits Higgsfield. Viser des clips d'au moins 30 s avec leur son ([consignes](medias/prompts-video.md)).
- **Nom** : le product owner voulait « Relax Rain New » avec presque le même logo que « Relax Rain » de mikdroid. **Refusé** : risque d'usurpation d'identité au sens de Google Play, de sanction du compte développeur (qui pourrait toucher CINAF si le compte est partagé) et de contrefaçon de marque.
  - Une recherche a vérifié 20 noms. **Rainlit, Rainlune et Rainfold** sont libres sur le web, et Ondée et Rainvale sont possibles.
  - Le product owner veut les mots « Relaxing & Sleep » : proposition « <Nom> : Relaxing & Sleep » dans le titre Play.
  - **Choix du nom en attente**, à faire suivre d'une vraie recherche de marques (TMview, EUIPO, classes 9, 41 et 42), du domaine et d'une icône originale (pas des gouttes sur une vitre).

**Fait** (trois agents en parallèle, fusionnés et vérifiés : `flutter analyze` sans remarque, 420 tests de l'app, 202 tests de l'API, ruff, migrations, Terraform validate et test, garde-fous) :
- **Retrait de la voix** : 4 migrations qui suppriment les tables et colonnes de la voix et des crédits (tables d'Eventide seulement) ; le secret Gemini et les alarmes de l'assistant sont retirés du Terraform (rien n'est appliqué) ; coûts recalculés : environ 8 USD par mois en phase 1, 18 au lancement. L'ancien fichier `voice_trial` est effacé du téléphone.
- **Ambiance de chaque paysage** : le son d'origine de la vidéo, sans le tonnerre, recomposé en boucle de plus de 60 s.
  - Pour `pluie-ville`, il n'y avait que 2,85 s de pluie sans tonnerre dans la source : **à écouter sur le S24**.
- **Tonnerre** : 10 variantes **provisoires**, fabriquées par ordinateur, à remplacer par de vrais enregistrements ou par Higgsfield. Pour chaque coup, l'éclair est dessiné par l'app de 0,4 à 3,5 s avant ; les éclairs sont retirés de la vidéo `pluie-ville`.
- **Rapport de problème** : raisons de sortie données par Android, journal des erreurs et de la mémoire, envoyé depuis Réglages › « Signaler un problème ».
  - Deux fuites de lecteurs vidéo, quand on fait défiler vite les paysages, sont corrigées. Ce n'est pas forcément la cause de l'arrêt.
- **Carte de l'écran verrouillé** : cause probable trouvée. `audio_service` ne donnait l'intention d'ouverture à la session qu'après l'avoir activée ; la nôtre est maintenant posée dès le démarrage du service.
- **Fond d'écran vidéo** : service de fond d'écran animé (muet, en pause quand il est caché), et « Enregistrer dans la Galerie » pour l'écran verrouillé de One UI.

**À vérifier à la main sur le S24** (détail dans [architecture § 15.6, § 16.4, § 17.5 et § 18.4](app/architecture.md)) :
- toucher la carte de l'écran verrouillé ;
- 30 à 40 minutes d'écoute, puis envoyer le rapport ;
- volume du tonnerre et naturel de l'ambiance ;
- fond d'écran animé, et vidéo enregistrée dans la Galerie ;
- version optimisée (R8).

## 29 octobre 2026 — carte de lecture, vérification sur émulateurs

- **Fait** : carte de lecture de l'écran verrouillé et des notifications, comme Spotify (`8df69fd`, [architecture § 15](app/architecture.md)) ; l'API accepte la clé `videos/paysages/<id>.mp4` (`f259325`).
- **Émulateurs de la CI** : sur les machines de GitHub, c'est l'émulateur qui plante, pas l'app. Le moteur de rendu de l'émulateur s'arrête net (SIGILL dans un fil « RenderThread », puis un vidage mémoire), au moment où l'app dessine sa première image. Cela arrive sur Android 14 et 16, quel que soit le mode graphique essayé (`swiftshader`, `swangle` ; `angle_indirect` est refusé). Ce qui en découle :
  - l'étape A (démarrage de la démo optimisée par R8) reste **bloquante**. Si l'émulateur tombe, elle est jugée sur ce que l'app a fait avant : processus lancé, « Eventide: demo mode on », aucun plantage, ANR ni erreur Dart de l'app ;
  - les étapes B (test d'intégration) et C (démarrage programmé) **ne bloquent plus**.
- **Passage 40797720083** (`502d4b8`) : tout est vert. Sur Android 14 et 16, la démo atteint le mode démo en 5 à 7 s, sans erreur de l'app ; l'émulateur plante 29 à 33 s après le lancement, avant la première image ; B et C n'ont pas pu tourner. **Non prouvé par la CI** : que la première image s'affiche et que l'app tient ensuite. Le lancement à la main sur le Galaxy S24 reste le test décisif. Fichier pour le S24 : artefact `eventide-demo-galaxy-s24-arm64` (12865301395).
- **Pistes si l'on veut une preuve sur appareil** : Firebase Test Lab (vrais téléphones dans le cloud, dont des Galaxy S24), qui demande un projet Google Cloud du product owner.

## 28 octobre 2026 (nuit) — vidéos de paysage, sourdine, mélodie d'accueil, démo

- **Vidéos de paysage** (décision du product owner) : le paysage doit sembler vivant et incrusté, jamais un lecteur vidéo ; **la pause n'arrête que le son**. Image fixe seulement en veille, avec « réduire les animations » et en arrière-plan. Boucles sans raccord (`tools/media/process_video.py`), image de départ identique à la première image de la boucle. `cascade-foret` (gratuit, dans l'app) et `pluie-ville` (Premium, S3) viennent de vidéos Gemini du product owner (usage commercial à confirmer) ; `toits-pluie` et `ciel-etoile` utilisent **deux vidéos YouTube de tiers, pour les tests internes seulement** (`medias-test/`, démo uniquement, garde-fous CI) : **à retirer avant toute bêta**.
- **Sourdine** « Sons de nature » / « Musique » qui garde les niveaux ; voix « coupe / remets la musique ».
- **Mélodie d'accueil** (décision du product owner) : chaque paysage démarre avec une mélodie douce qui monte en 20 s.
- **Démo Premium** (`be.cinaf.eventide.demo`) et contrôles Android en CI (alignement 16 Ko, émulateurs Android 14 et 16). La CI a révélé un **plantage au démarrage de la version optimisée** (R8 retirait la base de données de WorkManager) : corrigé ; et un arrêt de l'émulateur ~55 s après le début du son avec `-noaudio` : option retirée.
- **À faire** (mis à jour le 29 octobre) : ~~carte de lecture sur l'écran verrouillé~~ et ~~clé `videos/paysages/<id>.mp4` côté API~~ faites (voir le 29 octobre) ; vidéos 1080 × 1920 d'au moins 12 s ; décider si les images des paysages Premium servent d'aperçu aux utilisateurs gratuits ; envisager Git LFS (≈ 30 Mo de médias dans le dépôt).

## 28 octobre 2026 (soir) — règle de non-influence et audit de l'infrastructure

**Règle absolue du product owner**, inscrite dans [`AGENTS.md`](../AGENTS.md) et à recopier dans toute consigne d'agent touchant l'infra, la CI, le déploiement ou la base : CINAF, JobMinutes et Candidature Express restent intouchées et ne doivent être influencées en aucun cas par Eventide.

Audit indépendant de l'infrastructure (aucun appel AWS, fournisseurs simulés, sans identifiants) : sur les plans simulés, **0 modification, remplacement, suppression ou import** d'une ressource d'une autre plateforme ; objets posés sur des ressources de CINAF limités aux quatre points de contact de l'ADR. Corrections apportées :
- le rôle de déploiement GitHub ne lit plus ni n'enregistre de définitions de tâches hors d'Eventide (fonction Lambda `ev-<env>-task-registrar` dédiée) ;
- règles d'écoute limitées à nos noms d'hôte exacts et à nos priorités ; domaines des autres plateformes refusés ; la zone DNS doit porter notre étiquette ;
- amorçage de la base : refuse toute base ou tout rôle qui n'est pas à Eventide ; plafonds par rôle (mémoire, fichiers temporaires, sessions inactives, pas de parallélisme) ; secret temporaire du mot de passe maître chiffré par **notre** clé ;
- garde-fou `check-plan-additions-only.sh`, **obligatoire avant chaque `apply`** avec la relecture du plan par le product owner ; garde des ressources à l'échelle du compte étendue ;
- alarmes de charge sur l'instance PostgreSQL partagée actives par défaut ; pic Fargate plafonné par environnement.
Détail : [ADR § 11](infra/hebergement-mutualise.md).

**Risques résiduels à trancher par le product owner** (ADR § 11.4) :
1. Coûts facturés sur des ressources de CINAF : ≈ 3,5 à 4 USD/mois de NAT (téléchargement des images de conteneur) et < 1 USD/mois d'ALB. Prévenir CINAF, ou espacer la tâche horaire de finalisation des achats (÷ 4).
2. Le mot de passe maître de CINAF est lu une fois par le product owner pour l'amorçage ; alternative : CINAF exécute l'amorçage ou nous crée un rôle délégué.
3. Le rôle de la fonction d'enregistrement garde `RegisterTaskDefinition` sur `*` (restriction par famille non vérifiable ici).
4. Nos rôles peuvent se connecter aux bases qui laissent `CONNECT` à `PUBLIC` : seule CINAF peut le retirer chez elle.
5. Effets d'instance non plafonnables (autovacuum, journaux et statistiques de l'instance, nos données dans leurs instantanés) ; `temp_file_limit` peut ne pas être réglable sur RDS.
6. Toujours à confirmer : les règles de groupe de sécurité et d'écoute de CINAF sont-elles déclarées en ressources autonomes dans son Terraform ?

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
