# Journal de développement — Eventide

## 30 octobre 2026 — scènes 3D dans l'app, Imaginaire remplace Astral

- **Six scènes 3D validées** par le product owner (« tu as déjà ma validation »). Images fixes et boucles de fond d'écran des cinq scènes refaites rendues (`render.js video`) : 2,8 à 3,9 Mo, sous le plafond de 4 Mo des scènes 3D (contrat § 8). Le contrôle du raccord a trouvé un saut toutes les 30 s dans la mer de nuages (relief fin des nuages qui glissait sans boucler, visible aussi en direct) : corrigé, boucle refaite, raccord revenu à la normale. Mesures dans l'architecture § 20.4-20.5 ; aperçu republié (version 6).
- **Nom visible « Full Relax »** : nom sous l'icône (« Full Relax Démo » pour la démo), carte de l'écran de verrouillage, fond d'écran animé, partages, rapport de problème, réglages, pages web. Les noms techniques (`eventide`, `ev-`, identifiant `be.cinaf.eventide`, infrastructure) ne changent pas : aucune incidence sur CINAF, JobMinutes ni Candidature Express. Logo écrit : « Full Relax » en Cormorant Garamond 500, interlettrage 0,04 em, sans la goutte (choix par défaut, à confirmer par le product owner). Restent à faire : les fichiers de marque pour le Play Store (`app/assets/brand/wordmark.*`, `logo.svg`) et, si le logo écrit est confirmé, retirer la police Fraunces devenue inutile (360 Ko).
- **Forêt aux lucioles v2 validée** (« c'est correct ») : vraie forêt 3D, lune avec ombres, brume, finition HDR (`post.js`). Elle devient la **référence de qualité**. Les feuilles qui tombent sont retirées (incohérentes dans une forêt d'épicéas) ; plus aucune scène ne les propose, le décor `feuilles` quitte le catalogue.
- **Rubriques : Nature, Urbain, Imaginaire** (Astral retiré ; `ciel-etoile`, vidéo de test, passe dans Nature). Contrat § 12.
- **Fusion** de l'intégration 3D (WebView, décor non modifiable sur les vidéos réelles, éclair d'orage automatique) et des six scènes. Les boucles des scènes 3D peuvent aller jusqu'à 4 Mo (contrat § 8). Vérifications : 498 tests de l'app, 217 de l'API, CI 41054912607 verte ; démo S24 : artefact 12976324598.
- **Aller plus vite** (demande du product owner) : skill du projet `.claude/skills/scene-imaginaire/SKILL.md`. Il contient les règles du product owner, le budget du téléphone et la méthode : petites images fixes, aperçu à valider, longues vidéos seulement après validation, un agent par scène. Deux agents mettent en cours lac-lune, aurore, jardin-zen, mer-nuages et ondes au niveau de la forêt (aperçu d'abord).
- **Higgsfield** : le connecteur MCP ne fait que **lire** (solde, modèles, générations passées) et ne peut pas générer. Les générations se lancent sur le site, puis on les récupère par le connecteur. Compte gratuit, 10 crédits. Modèles utiles : FLUX 3 Video (20 s, 1080p, son synchronisé), Seedance 2.0.
- **Prompts vidéo Higgsfield** (`docs/medias/prompts-video.md`) : cinq urbains (`toits-pluie`, `cafe-nuit`, `rue-pavee`, `pluie-ville`, `verriere-pluie`) et quatre de nature (`cascade-foret`, `pluie-foret`, `vagues-crepuscule`, `ciel-etoile`), 20 s, 9:16, 1080p, son de la scène sans tonnerre ni éclair. Ils remplacent les deux médias de test YouTube et refont `pluie-ville` et `cascade-foret` ; les cinq nouveaux identifiants entreront au catalogue à l'intégration.

## 29 octobre 2026 (nuit) — nom, icône, police, vrai tonnerre, scènes 3D

**Décisions du product owner** :
- **Nom : « Full Relax »** : aucune application ni marque trouvée sous ce nom (recherche web, à confirmer sur TMview/EUIPO). Titre Play envisagé : « Full Relax : Relaxing & Sleep ». Renommage à faire après l'intégration des scènes 3D : seulement ce que l'utilisateur voit. Les noms techniques et l'infrastructure (`eventide`, `ev-`) ne changent pas. **À trancher avant publication** : l'identifiant d'application (`be.cinaf.eventide`), définitif une fois sur Play.
- **Icône** : photo d'orage générée par Gemini **à partir d'un texte seul** (confirmé ; source `medias-bruts/icone/`, outil `tools/media/make_icon_from_photo.py`), cadrage « A » avec l'éclair et les feuilles mouillées ; icône à thème : silhouette d'éclair et de feuille. Une image d'une vidéo YouTube de tiers a été écartée (droits).
- **Police « Galerie »** (option 2) : Cormorant Garamond 500 (italique pour les noms de paysages) et Manrope 400/500, capitales espacées pour les boutons ; **beaucoup moins de texte**, surtout dans les réglages. Le logotype garde Fraunces en attendant le renommage.
- **Décor non modifiable sur les vidéos réelles** ; nouvelle catégorie **« Imaginaire »** de scènes 3D (Three.js), où l'utilisateur ajoute des éléments ([contrat § 12](api/contrat-v1.md)). Les anciens paysages dessinés en 2D sont retirés.
  - Six scènes : forêt aux lucioles (gratuite), lac sous la lune, aurore boréale, jardin zen, mer de nuages, ondes lumineuses.
  - **L'intégration est prête mais pas fusionnée** : le product owner valide d'abord les scènes dans un aperçu (artifact) ; l'agent des scènes travaille encore.
  - **Correction** : une scène WebGL tourne sur le processeur graphique du processus de l'app. Un plantage du pilote arrêterait donc l'app ; la garde de démarrage et l'affichage de l'image fixe ensuite limitent le problème.
- **Tonnerre refait à partir du vrai enregistrement** de la vidéo `pluie-ville` (« un tonnerre ne frappe jamais d'un coup seul ») :
  - tonnerre séparé de la pluie, roulements prolongés, 17 morceaux réels ;
  - orages composés : grondement lointain seul (25 %), grondement puis éclair puis coup et roulement (55 %), coup proche suivi d'une réplique (20 %) ;
  - la pluie forcit après un coup ; les faux tonnerres sont supprimés ([contrat § 11](api/contrat-v1.md)).
- **Fond d'écran** : il disparaît à la désinstallation (comportement d'Android), ce qui convient au product owner.

**Vérifications** : 494 tests de l'app, 204 de l'API ; CI 40946895427 verte. Démo S24 : artefact 12929833664 (tonnerre réel, police, icône ; sans les scènes 3D).

## 29 octobre 2026 (soir) — plantage au bout du thème Nature, tonnerre, police

- **Plantage reproductible**, trouvé par le product owner : en faisant défiler le thème Nature jusqu'au dernier paysage (`lisiere-verte`), l'app s'arrêtait. Elle s'arrêtait ensuite **à chaque démarrage**, et il fallait la réinstaller.
  - **Cause** : les paysages dessinés étaient trop lourds pour le processeur graphique (milliers de flous et de découpes ; pour `lisiere`, une découpe en 26 ovales et 260 points flous). Ils étaient dessinés pour le paysage visible, ses voisins, la vignette et la carte de lecture. Le paysage était ensuite enregistré comme dernier paysage, donc redessiné à chaque démarrage.
  - **Correction** : dessins version 2 (aucune découpe, presque plus de flous ; mémoire de pointe ÷ 1,8), un seul dessin à la fois.
  - **Protection** : un démarrage interrompu fait repartir l'app sur `cascade-foret`, sans perdre favoris, programmations ni réglages ; un dessin interrompu est ensuite remplacé par une version simplifiée ; le rapport de problème nomme le dernier dessin ([architecture § 19](app/architecture.md)).
  - **Non prouvé** : le plantage exact du pilote graphique (Exynos 2400) ne se reproduit pas sans le téléphone.
- **Fond d'écran animé** : fonctionne sur l'écran d'accueil **et** l'écran verrouillé du S24. « Enregistrer dans la Galerie » est retiré.
- **Tonnerre** :
  - **Plus fréquent** : premier coup entre 20 s et 1 min, puis un toutes les 70 s à 3 min.
  - **Son jugé artificiel** : les variantes sont fabriquées par ordinateur, il faut de vrais enregistrements. Les sites de sons sont bloqués depuis la session. Le product owner peut en télécharger sur Pixabay et les envoyer, ou on les obtient avec Higgsfield.
- **Police jugée pas assez premium** : aperçu de quatre styles publié ([artifact](https://claude.ai/artifact/KtMrKznhbkvVz8jdizcgZj)). Recommandation : n° 2 « Galerie » (Cormorant Garamond pour les titres, Manrope plus légère pour le texte). **Choix du product owner en attente.** Les polices peuvent venir de npm (`@expo-google-fonts/*`, fichiers TTF) : npm et PyPI sont joignables, pas Google Fonts.
- **CI** : passage 40910734429 vert (Kotlin compilé, versions optimisées, alignement 16 Ko, démarrage sur émulateurs). Démo S24 : artefact 12915265395.

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
