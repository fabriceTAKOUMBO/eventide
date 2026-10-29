# Architecture de l'application Eventide (Flutter, Android)

Ce document décrit la couche applicative (`app/lib/app`), les services (`app/lib/services`) et le code natif Android (`app/android`). L'interface (`app/lib/ui`) et le domaine pur (`app/lib/core`) ont leurs propres conventions ; le contrat serveur est dans [`../api/contrat-v1.md`](../api/contrat-v1.md).

## 1. Modules

| Dossier | Rôle | Dépend de |
|---|---|---|
| `lib/core/` | Domaine pur, sans Flutter ni plugin : catalogue, document de scène, programmations, réglages, formules et droits (`ProductRules`), opérations de l'assistant (`validateOps`, `applyOps`), normalisation du français, règles vocales, codec de partage, nuits | rien |
| `lib/app/app_model.dart` | **Contrat entre l'interface et l'application** (`AppModel`, états de la voix, événements) | `core` |
| `lib/app/app_controller.dart` | `RealAppModel` : enchaîne les règles du domaine avec le stockage, l'audio, le réseau, les achats, la publicité et les démarrages programmés | `core`, `services` |
| `lib/app/bootstrap.dart` | Construit les services réels, dans le bon ordre (voir § 4) | tout |
| `lib/app/env.dart` | Configuration par `--dart-define` (§ 10) | — |
| `lib/app/demo_mode.dart` | Décisions de la version démo (§ 12) | `core` |
| `lib/app/sleep_tracker.dart` | Suivi du sommeil, méthode 1 du dossier (§ 9) | `core` |
| `lib/services/` | Accès à la plateforme, chacun derrière une interface remplaçable par un faux dans les tests | plugins |
| `lib/ui/` | Écrans « Vitre » ; ne connaît que `AppModel` et `core` | `app_model.dart`, `core` |
| `android/app/src/main/kotlin/` | Alarmes exactes, récepteurs, notifications de secours, Play Integrity, canal `be.cinaf.eventide/native` ; canal `be.cinaf.eventide/device` (`DevicePlugin` : rapport de problème § 16, intention de la carte de lecture § 15.3, fond d'écran § 17) ; service de fond d'écran animé (`LandscapeWallpaperService`, processus `:wallpaper`) | — |

Services : `storage.dart` (fichiers JSON), `api_client.dart` (API, jeton d'installation), `connectivity.dart`, `content_repository.dart` (sons, vidéos et images de paysages : embarqués, cache, téléchargements), `audio/` (moteur, focus, service de lecture), `voice/` (reconnaissance, chaîne vocale), `billing_service.dart`, `ads_service.dart`, `account_service.dart`, `links_service.dart` (feuille de partage, App Links, pages externes par `url_launcher`), `permissions_service.dart`, `native_bridge.dart`, `diagnostics.dart` (rapport de problème, § 16), `wallpaper_service.dart` (fond d'écran, § 17).

## 2. Flux de données

- L'interface appelle `AppModel` et écoute ses notifications (`ChangeNotifier`) et ses événements ponctuels (`events` : ouvrir Premium, Hors connexion, Veille, message…).
- **Le téléphone d'abord.** Tout l'état vit dans de petits fichiers JSON versionnés (`{"version": 1, "data": …}`) du dossier de support de l'application : `scene`, `schedules`, `favorites`, `settings`, `nights`, `entitlements`, `voice_trial`, `installation`, `app_state`. Chaque écriture est atomique (fichier temporaire, `flush`, renommage) et les écritures d'un même fichier sont mises en file. La scène est enregistrée 0,4 s après le dernier changement (curseurs), et immédiatement quand l'application passe en arrière-plan.
- Le serveur n'est appelé que pour une raison : installation (une fois), droits (au lancement si en ligne, après un achat), achats, voix (quand le modèle est nécessaire ou que l'essai doit être compté), liens de partage courts, adresses signées de contenu Premium, compte, export et suppression.
- « En ligne » veut dire qu'une vraie requête a réussi (`GET <API>/health`, puis `https://connectivitycheck.gstatic.com/generate_204`) ; `online` ne passe à faux qu'après un échec réel. Une panne de l'API seule ne bloque jamais un utilisateur gratuit.

## 3. Lecture audio

- **Moteur** (`SoLoudAudioEngine`, `flutter_soloud` 5) : une voix en boucle par couche (sons et musiques ; les décors sont visuels). Volume d'une couche = niveau / 100 × gain de catégorie (musique 0,8). Le volume global porte le plafond (0,85), la montée progressive, l'atténuation (*duck*), les fondus de pause et le fondu de fin.
- Les fichiers sont **lus depuis le disque** (`LoadMode.disk`) : décodée en mémoire, une boucle stéréo pèse environ 18 Mo pour 47 s ; six couches sur toute une nuit seraient trop lourdes pour un téléphone d'entrée de gamme. Les boucles fournies se raccordent à l'échantillon près dans ce mode.
- Départ de chaque couche à un endroit tiré au hasard (`seek`), longueurs de boucle différentes (23 à 47 s), légère variation lente et aléatoire du volume (± 7 % sur 20 s) : pas de répétition audible.
- Changement de paysage : fondu enchaîné de 2 s (une couche commune aux deux paysages glisse simplement vers son nouveau niveau). Changement de niveau : 0,4 s.
- **Mélodie de départ** : chaque paysage commence avec une musique douce et basse (15 à 25 %, `mix.musique` du catalogue ; mélodies gratuites pour les paysages gratuits). Elle **entre progressivement en 20 s** (`MixRules.musicEntry`) quand l'écoute part du silence (bouton lecture, notification, démarrage programmé) et quand le mix change de paysage (glissement, grille, voix, favori, lien de partage) ; les sons de nature gardent leur fondu (2 s). Une musique ajoutée ou réglée à la main, ou remise après une sourdine, revient en 1 s. Pour un démarrage programmé, la montée du volume global (`montee_minutes`) s'applique en plus : les deux gains se multiplient et ne dépassent jamais le niveau voulu. Après une pause, la musique revient en 3 s (`musicResume`), les sons avec le fondu global de 0,4 s. Le contrôleur décide (`EngineLayer.fadeIn`, `resumeFade`), le moteur exécute.
- **Sourdine** (« Sons de nature » et « Musique », contrat § 1) : couper une catégorie garde ses couches et leurs niveaux ; le volume de ses voix descend à 0 en 1 s, puis chaque voix est **mise en pause** (« garée ») ; la remettre relance la voix là où elle était et la refait monter en 1 s depuis le silence, sans raccord audible. Choix mesuré : une voix à volume 0 qui continue de tourner est toujours décodée et mixée par SoLoud (il ne saute que les voix au-delà de sa limite de 16) ; décoder une boucle Opus 48 kHz stéréo coûte environ 0,45 % d'un cœur de PC de bureau (mesuré avec `ffmpeg -benchmark`), plusieurs fois plus sur le petit cœur d'un téléphone d'entrée de gamme, toute la nuit, pour rien. Tout en sourdine : toutes les voix sont garées, le moteur est muet comme en pause (la sortie audio reste ouverte), mais la séance continue : minuteur, notification, et **la vidéo du paysage, jamais liée à l'état du son**. Un démarrage où tout serait en sourdine remet les deux catégories (un démarrage n'est jamais muet) ; une reprise après pause garde la sourdine. Toucher un niveau d'une catégorie en sourdine (curseur, − / +, ajout) la remet. La sourdine est enregistrée avec la scène, gardée au changement de paysage, jamais mise dans un favori ni un partage.
- **Pas de sortie audio** (émulateur sans son, pilote audio en panne) : l'ouverture du périphérique échoue ou ne répond pas en 15 s, le démarrage échoue proprement, le lecteur revient à l'arrêt et l'application affiche « Le son ne peut pas démarrer pour le moment » ; l'interface reste utilisable.
- **Service au premier plan** : `PlaybackHandler` (`audio_service`, type `mediaPlayback`) porte le moteur, la carte de lecture de l'écran verrouillé et des notifications (§ 15) et **le minuteur**, qui continue donc quand l'application est fermée. Fin du minuteur : fondu de 30 s, arrêt complet, l'écran n'est pas rallumé. « Toute la nuit » s'arrête après `limites.nuit_max_heures` (10 h). Le décompte est gelé pendant une pause.
- **Focus audio** (`audio_session`) : appel ou autre lecteur → pause, reprise automatique si l'interruption était passagère ; GPS ou notification → volume baissé ; casque débranché → pause. Balayer l'application hors des récentes laisse le son et son minuteur continuer.
- Le gratuit exige une connexion : avant de **démarrer** un son, un utilisateur gratuit fait une vraie vérification réseau (au plus une toutes les 2 minutes). Une écoute déjà en cours n'est jamais coupée ; seul le chargement d'un nouveau paysage ou d'un nouveau son est refusé hors connexion.
- **Contenus** (`ContentRepository`) : fichier embarqué `assets/audio/<sons|musiques>/<id>.ogg` s'il existe (éléments gratuits), sinon fichier déjà téléchargé, sinon téléchargement (adresse CloudFront signée par `POST /content/urls`, ou serveur local en debug). Pour Premium, tous les sons et musiques sont téléchargés en arrière-plan, un par un, en Wi-Fi seulement si le réglage est activé, puis les images fixes des paysages (les vidéos sont téléchargées quand leur paysage est affiché, § 14).

## 4. Démarrage programmé (le point le plus risqué)

Dart ne calcule rien au moment du déclenchement ; tout ce qui doit marcher application fermée est natif.

1. À chaque changement (programmation, formule, autorisation), Dart appelle `syncSchedules(json)` : les programmations actives (au plus une pour le gratuit), avec le nom du paysage, et `requires_network` (vrai pour le gratuit). Kotlin les garde dans `SharedPreferences` et arme **une seule** alarme, la prochaine occurrence : `AlarmManager.setAlarmClock` si `canScheduleExactAlarms()`, sinon `setAndAllowWhileIdle` (inexacte, peut arriver en retard). Le mode est renvoyé à Dart (`AlarmMode`).
2. Le calcul de la prochaine occurrence (`ScheduleStore.nextOccurrence`, `java.time`) suit exactement `Schedule.nextOccurrence` en Dart : heure locale murale, jours 1 = lundi … 7 = dimanche, strictement après maintenant ; « 22 h » reste 22 h après un changement d'heure ; une heure qui n'existe pas (passage à l'heure d'été) est décalée de la durée du saut. `java.time` est disponible dès Android 7 grâce au *desugaring*.
3. **`ScheduleAlarmReceiver`** au déclenchement :
   - alarme livrée plus d'une heure en retard (téléphone éteint) → ignorée : jamais de son au milieu de la nuit ;
   - enregistre la programmation en attente (`consumePendingStart`, valable 15 minutes) ;
   - utilisateur gratuit et aucun réseau → notification « Pas de connexion », pas de son ;
   - sinon démarre le service d'`audio_service` avec un événement `MEDIA_PLAY` (`ContextCompat.startForegroundService`), et crée tout de suite le moteur Flutter partagé pour y enregistrer notre canal natif (un moteur créé par le service ne passe jamais par `MainActivity`) ;
   - si Android refuse (`ForegroundServiceStartNotAllowedException`, typiquement sans alarme exacte) → notification de secours « C’est l’heure d’aller dormir » / « C’est l’heure de vous détendre » avec le bouton « Lancer » : il ouvre l'application, qui démarre la programmation en attente ;
   - réarme toujours l'occurrence suivante.
4. Côté Dart, `main()` enregistre le *handler* auprès d'`audio_service` **avant** tout le reste. Le *handler* reçoit le clic, publie aussitôt l'état « chargement » (la notification apparaît, ce qui respecte le délai d'Android pour un service au premier plan), lit `consumePendingStart()`, puis demande au contrôleur quoi jouer : mix par défaut du paysage de la programmation, montée depuis le silence sur `montee_minutes`, texte du rappel dans la notification. Si l'on écoute déjà quelque chose, la programmation ne coupe rien.
5. Journal : le récepteur Kotlin (étiquette logcat `EventideSchedule`) note l'armement (`armed: mode=exact|inexact`), le déclenchement, le démarrage demandé du service ou la notification de secours ; le *handler* Dart note `EventideSchedule: playback started…` ou `nothing played…`. La CI s'en sert (§ 10, émulateurs).
6. **`BootReceiver`** réarme après `BOOT_COMPLETED`, `TIME_SET`, `TIMEZONE_CHANGED`, `MY_PACKAGE_REPLACED` et `SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED`.
7. Autorisations : l'interface explique, puis `requestPermission(PermissionKind.exactAlarm)` ouvre « Alarmes et rappels » (`ACTION_REQUEST_SCHEDULE_EXACT_ALARM`) ; `PermissionKind.notifications` demande `POST_NOTIFICATIONS` (Android 13+). Une autorisation refusée définitivement (« Ne plus demander », `permissionPermanentlyDenied`) n'est plus demandée : l'interface propose « Ouvrir les réglages » (`openAppSettings()`, fiche de l'application), et l'état est relu au retour dans l'application. `openBatteryGuide()` ouvre la fiche de l'application (bouton « Ouvrir les réglages » du guide contre les fabricants qui arrêtent les applications).

Replis, du meilleur au moins bon : alarme exacte + son → alarme inexacte + son (si Android l'autorise) → notification « Lancer » → rien (notifications refusées). Le taux de réussite doit être mesuré pendant la bêta.

## 5. Voix

Écoute immédiate (`speech_to_text`, `fr_BE`, sinon `fr_FR`, sinon un autre français), un seul bouton d'arrêt, 20 s au plus, texte partiel et niveau sonore en direct. Puis : `normalizeFrench` → `parseWithRules` (gratuit, sur le téléphone) → sinon `POST /voice` → `validateOps` **à nouveau sur le téléphone** → `applyOps` provisoire (on entend tout de suite) → carte « C’est fait » avec Annuler (retour à l'état exact d'avant : scène, programmations, réglages, lecture, nuit en cours) ou Garder.

- Comptage côté serveur : pour le gratuit et l'à-vie, une phrase résolue par les règles est quand même envoyée avec `actions_locales` (elle compte) ; un abonné mensuel ou annuel ne fait pas d'appel dans ce cas.
- 402 `voice_quota_exhausted` → écran Premium (gratuit) ou achat de crédits (à vie). 402 `voice_monthly_cap`, 503, pas de serveur → règles seules, sans couper l'assistant. Hors connexion quand le modèle est nécessaire → message clair (`VoiceError(offline: true)`). Délai d'attente de la réponse : 5 s (objectif de bout en bout sous 3 s).
- Le son n'est jamais enregistré par l'application ; la transcription ne vit qu'en mémoire.
- « Coupe la musique », « arrête la musique », « mets la musique en sourdine » → `couper` (sourdine, réversible, réglages gardés) ; « enlève la musique » → `retirer` ; « remets la musique » → `remettre` (contrat § 3.1). L'annulation rend aussi l'état de sourdine d'avant.

## 6. Achats et droits

`in_app_purchase` (Billing Library 9) : abonnement `eventide_premium` (`monthly`, `annual` avec essai de 3 jours), `eventide_lifetime`, consommable `eventide_credits_50`. Les prix viennent de Google Play (prix récurrent de l'offre, essai détecté par une première phase à 0) ; les prix du dossier ne servent qu'à l'affichage quand Play ne répond pas. Chaque achat part à `POST /purchases`, qui le vérifie et l'acquitte (ou consomme les crédits). Sans réponse du serveur, l'achat n'est pas acquitté : Google le représente, « Restaurer mes achats » relance la vérification.

**Uniquement en debug et sans `API_BASE_URL`** : l'achat est acquitté sur le téléphone, sans vérification, pour tester les écrans. Jamais en version de production.

Les droits sont mis en cache : Premium marche hors ligne ; un abonnement expiré reste valable 7 jours sans contact avec le serveur, puis l'application repasse en gratuit. `DEBUG_FORCE_PLAN` force une formule en debug.

## 7. Publicité

Gratuit seulement : formulaire de consentement de Google (UMP) **avant** toute requête, contenu limité à la catégorie « G », interstitiel à l'ouverture et au retour depuis l'Accueil (`beforeExit()`), jamais pendant une lecture ni un chargement, au plus une fois toutes les 4 h par emplacement. Le formulaire de Google reste accessible par « Choix publicitaires » dans Confidentialité et données (`openAdPrivacyOptions()`, gratuit seulement). Identifiants de test de Google par défaut. À vérifier avant la soumission : les règles AdMob sur les interstitiels à l'ouverture et à la sortie (le format « App Open » est l'alternative prévue par Google pour l'ouverture).

## 8. Compte, données, partage

- Connexion Google facultative (`google_sign_in` 7) : jeton d'identité → `POST /account/google`.
- Export : tout ce qui est sur le téléphone (sauf le jeton) et, si possible, l'export du serveur, en JSON lisible. Suppression : `DELETE /account` puis effacement local complet (fichiers, contenus téléchargés, jeton, programmations natives).
- Pages externes (`url_launcher`, intention `ACTION_VIEW`, sans `canLaunchUrl` donc sans `<queries>` dans le manifeste) : « Gérer mon abonnement » ouvre `https://play.google.com/store/account/subscriptions?sku=eventide_premium&package=be.cinaf.eventide` ; la politique de confidentialité est `https://<SHARE_HOST>/confidentialite` (page à publier avec le domaine). Si rien ne peut ouvrir le lien, un message dit où aller.
- Aides affichées une seule fois (« Balayez pour changer de paysage ») : `hintSeen` / `markHintSeen`, gardées dans `app_state` (`hints_seen`), effacées avec les données.
- Partage : lien court du serveur `https://<hôte>/m/<code>`, ou lien autonome `https://<hôte>/s#<données>` hors ligne. Réception par App Links (`android:autoVerify="true"`, hôte = propriété Gradle `eventide.shareHost`, à aligner avec `SHARE_HOST` et `/.well-known/assetlinks.json`). Un destinataire gratuit voit les éléments Premium verrouillés et muets (`SharedMixOpenedEvent`) ; un paysage verrouillé est seulement montré, le son en cours continue.

## 9. Sommeil

Méthode 1 du dossier, sans capteur ni autorisation, calculée et gardée sur le téléphone. Quand le suivi est activé, une nuit commence avec « Commencer la nuit » (ou une programmation « Pour dormir ») ; elle se termine au premier réveil de la Veille ou retour dans l'application au moins 3 h après, ou à l'arrêt du son au moins 3 h après. Une nuit restée ouverte plus de 16 h est abandonnée (le chiffre serait inventé). Gratuit : dernière nuit seulement ; Premium : historique.

## 10. Configuration et lancement

| `--dart-define` | Défaut | Effet |
|---|---|---|
| `API_BASE_URL` | vide | URL de l'API, par exemple `https://api.eventide.app/v1`. Vide : aucun serveur, voix par règles seules, achats non vérifiés (debug) |
| `SHARE_HOST` | `eventide.app` | Hôte des liens de partage (domaine pas encore acheté) |
| `DEV_CONTENT_BASE_URL` | vide | **Debug seulement** : serveur local des contenus Premium, sans signature |
| `PLAY_CLOUD_PROJECT_NUMBER` | vide | Projet Google Cloud lié à Play Integrity ; présent → requête *standard* (`requestHash`, ce que vérifie l'API), absent → requête *classique* |
| `GOOGLE_SERVER_CLIENT_ID` | vide | Identifiant client web pour le jeton d'identité Google |
| `ADMOB_INTERSTITIAL_OPEN`, `ADMOB_INTERSTITIAL_EXIT` | identifiants de test Google | Blocs d'annonces |
| `DEBUG_FORCE_PLAN` | vide | **Debug seulement** : `free`, `monthly`, `annual`, `lifetime` |
| `APP_VERSION` | `1.0.0` | Envoyée à `POST /installations` |
| `DEMO_MODE` | `false` | Version démo (§ 12), **seulement** avec la propriété Gradle `eventide.demo=true` |

Propriétés Gradle : `-Peventide.shareHost=…` (filtre App Links), `-Peventide.admobAppId=…` (identifiant d'application AdMob, celui de test par défaut) et `-Peventide.demo=true` (paquet de la version démo, § 12 ; avec `flutter build`, s'écrit `--android-project-arg=eventide.demo=true`).

Exemples :

```bash
cd app
flutter run                                    # tout local
flutter run --dart-define=DEBUG_FORCE_PLAN=annual

# Émulateur Android avec l'API locale et les contenus Premium servis depuis content/
python3 -m http.server 8080 --directory ../content &
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000/v1 \
  --dart-define=DEV_CONTENT_BASE_URL=http://10.0.2.2:8080
```

`10.0.2.2` est la machine hôte vue depuis l'émulateur ; le trafic `http` n'est autorisé que dans le manifeste de debug.

### Signature de la version de production

Créer `app/android/key.properties` (jamais dans git, déjà ignoré, comme `*.jks`) :

```properties
storePassword=…
keyPassword=…
keyAlias=upload
storeFile=/chemin/vers/upload-keystore.jks
```

Sans ce fichier, `flutter build appbundle` signe avec la clé de debug (utile pour la CI, refusé par Google Play).

### Intégration continue

`.github/workflows/app.yml` (aucun identifiant cloud, aucun secret, aucun déploiement) :

| Tâche | Ce qu'elle prouve | Artefacts |
|---|---|---|
| `build` | Aucun fichier de `medias-test/` (matériel de tiers, non diffusable) sous `content/` ni `app/assets/`, ni par le nom ni par le contenu (`app/tool/ci/check_test_media.sh`) ; `flutter analyze`, `flutter test`, `flutter build apk --debug` : le Kotlin et Gradle compilent (impossible sans accès à Google Maven) | `eventide-debug-apk` |
| `release-apks` | Versions *release* (R8) de production puis de démo, arm64-v8a et x86_64, signées avec la clé de debug ; l'APK de production n'a **aucun** son Premium (`assets/flutter_assets/assets/audio/sons/vagues.ogg` absent), **aucune** vidéo ni image de paysage Premium (`content/videos`, `content/images`) ni aucun fichier de `medias-test/`, mais la vidéo gratuite `cascade-foret` ; paquet `be.cinaf.eventide`, nom « Eventide » ; l'APK de démo a tous les sons et musiques de `content/audio`, toutes les vidéos et images de `content/` et de `medias-test/`, paquet `be.cinaf.eventide.demo`, nom « Eventide Démo » (`app/tool/ci/check_apk_contents.sh`) | `eventide-demo-galaxy-s24-arm64` (à installer sur le téléphone), `eventide-demo-emulator-x86_64`, `eventide-production-release-apks-debug-signed` |
| `page-alignment` | Pages de 16 Ko (Android 15+ et Google Play pour une cible ≥ 35) : chaque `lib/arm64-v8a/*.so` et `lib/x86_64/*.so` a des segments `LOAD` alignés sur au moins `0x4000`, et `zipalign -c -P 16 -v 4` passe (`app/tool/ci/check_16kb_alignment.sh`, qui nomme la bibliothèque fautive) | — |
| `emulator` (API 34 et 36) | Sur de vrais systèmes Android (émulateurs x86_64, écran 1080 × 2400 à 420 ppp, démarrés à froid à chaque fois, sans instantané ; rendu logiciel `swangle_indirect`, sans Vulkan invité ni décodeur vidéo de l'hôte ; animations coupées, donc paysages en image fixe, sans vidéo). **A. Bloquant** : l'APK *release* de démo s'installe, démarre (`am start -W` ; s'il abandonne au bout de 10 s, la première image doit être signalée par « Displayed » dans les 120 s), passe en mode démo, reste en vie 15 s de plus, sans `FATAL EXCEPTION`, ANR ni erreur Dart. Si l'émulateur lui-même meurt pendant ce temps, c'est un **avertissement d'infrastructure**, pas un échec de l'application, et A est jugé sur ce qui s'est passé avant : le processus de l'application a démarré, « Eventide: demo mode on » est apparu, et aucune `FATAL EXCEPTION`, ANR ou erreur Dart de l'application n'a été écrite. B et C sont **non bloquants**, chacun avec son étape de verdict : B. le test d'intégration (`integration_test/demo_flow_test.dart`, `flutter drive`) : Bienvenue, lecture et pause, un son Premium, un paysage Premium, une programmation, « Version démo » dans Réglages ; C. la programmation laissée par B se déclenche application en arrière-plan, et le chemin suivi (service de lecture ou notification « Lancer ») est noté (`app/tool/ci/emulator_checks.sh`). Pourquoi : du 28 au 29 octobre 2026, à chaque exécution, sur API 34 comme 36, le processus de l'émulateur a planté 8 à 15 s après le lancement, pendant que l'application dessinait sa première image OpenGL ES (`SIGILL` dans un fil « RenderThread » du rendu de l'hôte, puis un vidage mémoire d'environ 50 s), avec `swiftshader_indirect` comme avec `swangle_indirect`, depuis un instantané ou à froid (`angle_indirect` est refusé par cet émulateur) ; l'application avait atteint le mode démo sans plantage ni ANR. Le Galaxy S24 dessine avec Impeller sur Vulkan, sans ce traducteur. Ce qui garantit encore le téléphone : A (version optimisée R8, démarrage, mode démo, aucun plantage de l'application sur Android 14 et 16), le même parcours que B joué sans appareil par les tests unitaires (`test/app/demo_flow_host_test.dart`), et l'essai sur le téléphone lui-même (§ 13). Si l'émulateur se fige ou plante (son processus n'utilise plus le processeur : bloqué, ou en train d'écrire son vidage mémoire), ses fils d'exécution et leurs piles ou le signal fatal (`gdb`) sont relevés une fois ; s'il disparaît, le journal de la tâche donne ce relevé, la mémoire et le processeur de l'émulateur toutes les 5 s, le journal du noyau de la machine, les rapports de plantage de l'émulateur et un extrait du journal Android enregistré en continu (lignes de l'application, plantages, son, codecs, rendu, puis les dernières lignes) | `emulator-api-34`, `emulator-api-36` : captures d'écran, logcat, `dumpsys`, `integration-test.txt`, `scheduled-start.txt`, `host-monitor.txt`, `emulator-freeze.txt` |

Les étapes du test d'intégration sont aussi jouées sans appareil par `test/app/demo_flow_host_test.dart` (vrai `RealAppModel` et vraie interface, services simulés).

## 11. Ce qui doit être testé sur de vrais téléphones

Les tests unitaires couvrent la logique (faux pour chaque plugin) ; tout ce qui suit dépend d'Android et des fabricants (dossier, § 8 « Qualité et tests ») :

- Parc : Samsung série A, Xiaomi ou Redmi, Pixel, Motorola ; Android 12 à 16 ; au moins un petit écran et un appareil d'entrée de gamme.
- **Programmations sur 14 nuits consécutives** par téléphone, application fermée et écran éteint : avec et sans autorisation d'alarme exacte, après redémarrage, après changement d'heure et de fuseau, après mise à jour de l'application ; vérifier la notification « Lancer » quand le démarrage est refusé, et « Pas de connexion » pour un gratuit en mode avion. Mesurer le délai entre l'heure prévue et le son.
- Démarrage à froid du moteur Flutter par le récepteur dans le délai d'Android (environ 10 s) sur l'appareil le plus lent.
- **Lecture de 8 h écran éteint** : batterie, aucune coupure, aucun raccord audible, mémoire stable ; fin du minuteur (fondu, arrêt, écran éteint), « Toute la nuit » à 10 h.
- Focus audio : appel entrant, GPS, autre lecteur, casque filaire et Bluetooth débranchés.
- Voix : disponibilité de la reconnaissance française hors ligne, `fr_BE`, voix âgées, bruit ; 200 phrases ; temps de réponse.
- Achats en test interne Google Play (essai de 3 jours, restauration, crédits, remboursement), consentement publicitaire depuis l'Europe, App Links vérifiés une fois le domaine acheté, TalkBack et police à 200 %.
- **Carte de lecture** (§ 15) : sur le Galaxy S24, la liste du § 15.6.
- **Rapport de problème** (§ 16) et **fond d'écran vidéo** (§ 17) : les listes du § 16.4 et du § 17.5.
- **Paysages vivants** (§ 14) : aucune image noire au démarrage, au raccord de la boucle ni au retour d'arrière-plan ; passage image fixe → vidéo invisible (comparer aussi les couleurs : la matrice BT.601 des vidéos Veo doit être respectée par le décodeur) ; aucun accroc au moment où la boucle recommence ; le son continue sans interruption quand la vidéo démarre (aucune demande de focus audio) ; batterie et chaleur sur 30 min écran allumé ; mémoire stable après 50 balayages ; un téléphone d'entrée de gamme.

## 12. Version démo

Une version pour montrer et tester l'application sur un téléphone **sans Google Play ni serveur**, avec Premium déjà actif. Elle ne peut pas être confondue avec la production ni publiée à sa place :

- **Deux verrous.** La propriété Gradle `eventide.demo=true` donne un autre paquet (`be.cinaf.eventide.demo`, suffixe `.demo`), le nom « Eventide Démo » sous l'icône et un drapeau dans le manifeste (`be.cinaf.eventide.DEMO_BUILD`, lu par `NativeBridge.isDemoBuild()`). Le Dart n'active le mode démo que si ce drapeau **et** `--dart-define=DEMO_MODE=true` sont présents (`DemoMode.resolve`) : un paquet de production compilé par erreur avec la *dart-define* reste normal, et l'APK de démo, signé par la clé de debug et d'un autre paquet, serait refusé par Google Play.
- **Construction** (comme la CI) :

  ```bash
  cd app
  bash tool/ci/bundle_demo_media.sh   # sons, musiques, vidéos et images Premium + matériel de test : démo seulement
  flutter build apk --release --split-per-abi --target-platform android-arm64 \
    --dart-define=DEMO_MODE=true --android-project-arg=eventide.demo=true
  git checkout -- assets && git clean -f assets/audio assets/landscapes   # ne jamais committer ces copies
  ```

- **Ce qui change** : droits forcés à la formule annuelle (Premium, assistant inclus), quel que soit le cache ; aucun appel au serveur pour les droits ; aucune publicité (`NoAdsService`) ; aucun appel à Google Play (`DemoBilling`) : l'écran Premium dit « Version démo : Premium est déjà actif », ses boutons sont désactivés, « Restaurer mes achats » répond par un message, « Gérer mon abonnement » n'existe pas ; écoute hors connexion et programmations sans limite ; voix par les règles du téléphone (sans `API_BASE_URL`, jamais de message de quota) ; mention discrète « Version démo » en bas de Réglages.
- **Sons et paysages Premium embarqués** : la CI (`app/tool/ci/bundle_demo_media.sh`) copie `content/audio/sons/*.ogg` et `content/audio/musiques/*.ogg` dans `app/assets/audio/`, `content/videos/paysages/*.mp4` et `content/images/paysages/*.jpg` dans `app/assets/landscapes/` **avant** la construction de la démo seulement ; `ContentRepository` préfère les fichiers embarqués. La CI vérifie que l'APK de production n'en contient aucun.
- **Matériel de test non diffusable** : les vidéos de tiers de `medias-test/` (YouTube, tests internes du product owner : `toits-pluie`, `ciel-etoile`) sont copiées de la même façon, dans la démo seulement ; elles sont à retirer avant toute bêta, même fermée (`medias-test/LISEZMOI.md`, `content/LICENCES.md`).

## 13. Installer sur un téléphone (version démo)

Pour le Samsung Galaxy S24 (Android 14 à 16, One UI 6 à 8) ; les autres téléphones Android 7 et plus récents suivent le même chemin, avec d'autres noms de menus.

1. **Télécharger** : sur GitHub, onglet *Actions*, flux « app », dernière exécution réussie de la branche voulue, section *Artifacts* : `eventide-demo-galaxy-s24-arm64` (il faut être connecté à GitHub). C'est un fichier `.zip`.
2. **Décompresser** : il contient `eventide-demo-galaxy-s24-arm64.apk`. Sur le téléphone, *Mes fichiers* (Samsung) ouvre le `.zip` et propose « Extraire » ; sinon décompresser sur l'ordinateur et copier l'APK par câble USB, Google Drive ou courriel à soi-même.
3. **Installer** : toucher l'APK dans *Mes fichiers*. Android demande d'autoriser cette source : « Paramètres » → activer « Autoriser depuis cette source » pour *Mes fichiers* (ou Chrome, Drive… selon l'application qui ouvre le fichier), puis revenir et « Installer ».
   - Si l'installation est bloquée par le **Bloqueur automatique** de Samsung (*Paramètres* → *Sécurité et confidentialité* → *Bloqueur automatique*), le désactiver le temps de l'installation, puis le réactiver.
   - **Play Protect** peut prévenir qu'il ne connaît pas l'application (« Application inconnue » / « Application non sécurisée bloquée ») : *Plus de détails* → *Installer quand même*. S'il propose d'envoyer l'application pour analyse, les deux réponses conviennent. C'est attendu : l'APK est signé par la clé de test de la CI, pas par Google Play.
4. **Premier lancement** : l'icône s'appelle **« Eventide Démo »** ; elle peut cohabiter plus tard avec l'application « Eventide » de Google Play (autre paquet, données séparées).
5. **Mettre à jour** : installer le nouvel APK par-dessus l'ancien (en principe la CI garde la même clé d'une exécution à l'autre ; les réglages sont alors conservés). Si Android répond « Application non installée » ou « en conflit avec un paquet existant », désinstaller d'abord l'ancienne version.
6. **Désinstaller** : appui long sur l'icône « Eventide Démo » → *Désinstaller*, ou *Paramètres* → *Applications* → *Eventide Démo* → *Désinstaller*.
7. **Si le téléphone refuse toute installation hors Google Play** (règles de l'entreprise, ou vérification des développeurs que Google déploie pays par pays depuis 2026) : installer depuis un ordinateur par câble USB, *Options de développement* → *Débogage USB* activé, puis `adb install -r eventide-demo-galaxy-s24-arm64.apk`.

**Ce que fait la démo** : tous les paysages, sons, musiques et décors (sons Premium dans l'APK, écoute sans connexion), programmations sans limite, minuteur, Veille, sommeil, partage par lien autonome, voix pour les phrases simples reconnues sur le téléphone (« Ajoute du piano doux », « Arrête dans une heure », « Ajoute plus de pluie »…), sans publicité.
**Ce qu'elle ne fait pas** : aucun achat ni restauration (l'écran Premium dit « Version démo : Premium est déjà actif »), aucun serveur (pas de compte Google relié, pas de lien de partage court, pas de modèle pour les phrases complexes), pas de mise à jour par Google Play.

**Réglages Samsung pour les programmations** (sinon One UI peut endormir l'application et le son ne démarre pas à l'heure) :

- *Paramètres* → *Applications* → *Eventide Démo* → *Batterie* → **Non restreinte**.
- *Paramètres* → *Batterie* (ou *Entretien de l'appareil* → *Batterie*) → *Limites d'utilisation en arrière-plan* : Eventide Démo ne doit figurer ni dans **Applications en veille** ni dans **Applications en veille prolongée** (« veille profonde ») ; l'ajouter aux **Applications jamais mises en veille** et, au besoin, désactiver « Mettre en veille les applications inutilisées ».
- *Paramètres* → *Applications* → *Eventide Démo* → **Alarmes et rappels** : autorisé (la carte « Autoriser » de l'écran Programmations y mène) ; **Notifications** : autorisées (rappel et commandes du son).
- Test rapide : programmer un départ dans 5 minutes, verrouiller l'écran, attendre. Le son doit démarrer avec sa notification ; sinon une notification « C’est l’heure… » avec « Lancer » apparaît (Android a refusé le démarrage en arrière-plan) : revoir les réglages de batterie ci-dessus.

**Voix sur un Samsung** : l'application utilise le service de reconnaissance vocale choisi dans le téléphone. Selon la version de One UI : *Paramètres* → *Applications* → *Choisir les applications par défaut* → *Application d'assistance numérique* → *Saisie vocale* (ou *Gestion globale* → *Clavier Samsung* / *Saisie vocale*). Le service **Google** (« Services vocaux de Google ») reconnaît bien le français, aussi hors connexion une fois le pack « Français » téléchargé dans ses réglages ; le service **Samsung** fonctionne aussi mais peut demander internet. Si l'assistant répond « La reconnaissance vocale n'est pas disponible », choisir le service Google ou installer l'application Google.

## 14. Paysages vivants (vidéos)

Le paysage plein écran (Accueil, Bienvenue, Hors connexion) est un **paysage vivant** : une courte vidéo en boucle, muette, fondue dans l'interface. Exigence du product owner : elle ne doit **jamais** donner l'impression d'une vidéo ni d'un lecteur.

- **Chaîne de priorité** (`LandscapeBackground`, `lib/ui/landscape/landscape_background.dart`) : vidéo (si le paysage en a une, que la formule l'autorise et qu'elle peut être lue maintenant) → image fixe (l'image 0 de la boucle) ou photo → dessin procédural. Même cadrage (`BoxFit.cover`, plein écran sous les panneaux de verre), même filtre de moment de la journée, même flou ; le décor et les panneaux restent au-dessus ; l'image suit le doigt pendant un balayage comme avant. Le mouvement lent (*Ken Burns*) ne s'applique qu'aux images fixes des paysages **sans** vidéo : l'image fixe d'un paysage vidéo reste exactement là où la vidéo apparaîtra.
- **Jamais de lecteur visible** : pas de commandes, pas de roue d'attente, jamais d'image noire. L'image fixe est la première image de la boucle encodée (`tools/media/process_video.py`) ; elle reste affichée tant que la vidéo n'a pas produit ses premières images (lecture en cours et position qui avance), puis la vidéo apparaît par-dessus en 0,24 s, identique au pixel près. Boucle sans raccord dans le fichier (fondu enchaîné, mesures dans `tools/media/README.md`) et lecture en boucle d'ExoPlayer (`REPEAT_MODE_ALL`, sans coupure entre deux tours).
- **Jamais liée au son** : lecture/pause (bouton, notification, voix, perte du focus audio, fin du minuteur) et sourdine ne changent que le son ; aucun chemin commun entre l'état du son et la vidéo (`LandscapeBackground` ne lit jamais `AppModel.playing`, testé). La vidéo ne demande jamais le focus audio (`mixWithOthers`), sinon elle mettrait en pause le son de l'application, et elle n'a pas de piste son.
- **Quand la vidéo joue** : paysage à l'écran (aucun autre écran par-dessus : `TickerMode`), application au premier plan (`AppLifecycleState.resumed`), animations autorisées. **Trois exceptions, où une image fixe est utilisée** :
  1. **Veille** (écran noir) : elle recouvre l'Accueil ; la vidéo se met en pause sur son image, et son lecteur est libéré après 20 s (`releaseWhenCovered`) ; même chose sous tout autre écran (Paysages, Mon mix…), dont le retour dans les 20 s reprend exactement à la même image.
  2. **« Réduire les animations »** d'Android (`MediaQuery.disableAnimations`, accessibilité) : image fixe, aucun lecteur créé.
  3. **Application en arrière-plan** : rien ne joue ; le lecteur est libéré (`hidden`/`paused`). Au retour, l'image fixe (image 0) s'affiche puis la boucle repart de l'image 0 : aucun saut entre l'image fixe et la vidéo. Volet de notifications ou boîte de dialogue système (`inactive`) : simple pause sur l'image en cours.
- **Mémoire et batterie** (`LandscapeVideoHub`, `lib/ui/landscape/landscape_video.dart`) : un lecteur par vidéo, partagé par les widgets qui la montrent (Bienvenue → Accueil sans recharger), **deux au plus** : le paysage affiché et, pendant un balayage, le voisin qui arrive (il démarre sur son image fixe et devient le paysage courant sans être recréé ; un balayage annulé le libère). Un lecteur est libéré dès que plus rien ne l'affiche. Le son suit toujours le balayage après 1,5 s, l'image et la vidéo du nouveau paysage apparaissent tout de suite (image fixe d'abord). Les images fixes des voisins sont décodées à l'avance, et celles des vignettes à leur taille d'affichage (`ResizeImage`).
- **Origine des vidéos** (`AppModel.landscapeVideo`, `ContentRepository.landscapeVideo`) : fichier embarqué `assets/landscapes/<id>.mp4` (paysages gratuits ; dans la démo, aussi les paysages Premium et le matériel de test) ; sinon, pour Premium, fichier déjà téléchargé, sinon téléchargement unique de `images/paysages/<id>.jpg` puis `videos/paysages/<id>.mp4` (adresse signée de `POST /content/urls`, contrat § 8, ou `DEV_CONTENT_BASE_URL` en debug), gardé dans le dossier des contenus. Seules les clés listées dans `assets/landscapes/remote.json` sont demandées. « Téléchargements en Wi-Fi seulement » : aucune vidéo ni image téléchargée sur données mobiles. Un utilisateur gratuit sur un paysage Premium verrouillé voit son image fixe si elle est sur le téléphone (sinon le dessin), comme avant : **aucune vidéo n'est demandée ni téléchargée** pour lui.
- **Fichiers** : H.264 High, yuv420p, sans son, 720 × 1280 pour les vidéos Veo (24 i/s), image clé toutes les 2 s, sans images B, 2,5 Mo au plus par boucle ; lecture par `video_player` (ExoPlayer de Media3, vue en texture).
- **Décodeurs** : deux lecteurs au plus **en comptant ceux en cours de libération** (`LandscapeVideoHub.releasingCount`, 3 s au plus) : des balayages rapides n'empilent jamais de décodeurs matériels ; un lecteur libéré pendant son ouverture attend la réponse de celle-ci (5 s au plus) avant d'être libéré (`video_player` laissait sinon l'ouverture continuer sur un lecteur déjà libéré). Ouvertures et libérations sont notées dans le journal du rapport de problème (§ 16).
- **Qualité d'image** : sur un Galaxy S24 (1080 × 2340), une vidéo 720 × 1280 en `cover` est agrandie 1,83 fois (rognée d'environ 18 % sur les côtés) : nette mais un peu douce de près. Des sources 1080 × 1920, comme le demandent les consignes (`docs/medias/prompts-video.md`), seraient agrandies 1,22 fois.

## 15. Carte de lecture (écran verrouillé et notifications)

Comme Spotify : quand le son joue en arrière-plan ou écran verrouillé, Android (One UI sur le Galaxy S24) affiche une **carte de lecture** déployée (grande image, titre, sous-titre, barre de progression, boutons) ou repliée (compacte), sur l'écran verrouillé, l'Always On Display, le volet des notifications et la sortie média (Bluetooth). Cette carte est dessinée par le système à partir de la session média et de la notification `MediaStyle` d'`audio_service` : l'application ne fait que lui donner des données justes.

### 15.1 Ce que montre la carte

- **Titre** : nom du paysage (« Cascade en forêt »). **Sous-titre** : le mix qu'on entend, sons puis musiques dans l'ordre du mix (« Eau vive · Oiseaux · Piano doux ») ; une catégorie en sourdine, un niveau à 0 ou un élément verrouillé par la formule n'y figurent pas ; tout en sourdine : « Son en sourdine ». **Album** : « Eventide ». Le texte du rappel d'une programmation (« C’est l’heure d’aller dormir ») devient la troisième ligne de la notification (Android 12 et moins ; Android 13+ n'affiche que titre et sous-titre). Version démo : identique.
- **Image** : le paysage, en fichier local (`audio_service` n'accepte que `file://` et `content://`). Dans l'ordre : l'image fixe embarquée `assets/landscapes/<id>.jpg`, copiée une fois dans le cache (`media_art/<id>-<empreinte>.jpg`, nommée d'après son contenu : jamais d'image périmée après une mise à jour) ; sinon l'image téléchargée pour Premium (`images/paysages/<id>.jpg`) ; sinon le **dessin procédural** du paysage au moment de la journée, rendu hors écran en PNG carré 720 × 720 (`media_art/<id>-<moment>-v1.png`). L'image suit le paysage et, pour le dessin, le moment. Elle n'est fabriquée que pendant une écoute, **jamais avant le son** : la carte est publiée d'abord, l'image ajoutée quand elle est prête (le dessin est abandonné après 10 s, par exemple sans processeur graphique). Android peut vider le cache : les fichiers sont refaits.
- **Barre de progression = minuteur** : durée = longueur du minuteur (« Toute la nuit » : `limites.nuit_max_heures`, 10 h) ; position = temps écoulé depuis le départ du minuteur, figée pendant une pause, **repartie de 0** quand le minuteur change ; pleine pendant le fondu de fin. Le système fait avancer la barre lui-même (position, vitesse 1, heure de mise à jour). « Sans minuteur » : pas de durée, donc pas de barre. La barre est **informative** : aucune action « déplacer » (*seek*) n'est proposée et une demande de déplacement est ignorée.

### 15.2 Boutons (déployée : jusqu'à 5 ; repliée : lecture/pause et suivant)

| Bouton | Effet | Description (TalkBack) |
|---|---|---|
| Paysage précédent / suivant | Paysage voisin **dans le thème**, les paysages verrouillés pour la formule sont sautés, **pas de boucle** : bouton absent au bord. Même chemin qu'un balayage de l'Accueil : la carte change tout de suite, le son suit après 1,5 s (plusieurs touchers rapides : seul le dernier paysage est chargé) avec le mix par défaut et la mélodie qui monte en 20 s ; l'Accueil et sa vidéo suivent si l'application est visible ; jamais un paysage verrouillé | « Paysage précédent », « Paysage suivant » |
| Lecture / pause | **Le son seulement**, comme partout : la vidéo du paysage n'est jamais liée à l'état du son | « Lecture », « Pause » |
| Cœur | Ajoute ou retire la scène des favoris (rempli si elle en est un), sans message. À la limite gratuite (3 favoris) : rien, le cœur reste vide ; l'application propose Premium quand on l'ouvre. Pendant un précédent/suivant en attente, le paysage montré est d'abord chargé | « Ajouter aux favoris », « Retirer des favoris » |
| Minuteur | 15 min → 30 min → 1 h → 2 h → Toute la nuit → Sans minuteur → 15 min (une durée hors cycle, réglée à la voix, passe à l'étape suivante). L'icône montre l'état actuel (« 15 », « 30 », « 1h », « 2h », lune, minuteur barré) | « Minuteur 30 min. Toucher pour 1 h », « Minuteur toute la nuit. Toucher pour l’enlever », « Sans minuteur. Toucher pour 15 min » |

- Android 13+ construit la carte depuis la session : lecture/pause, puis précédent/suivant s'ils sont permis, puis les actions personnalisées (cœur, minuteur) dans l'ordre ; au bord d'un thème, Android peut placer le cœur à l'emplacement du bouton absent. Android 12 et moins : la notification montre précédent, lecture/pause, suivant (vue compacte : lecture/pause et suivant) ; `audio_service` n'y met pas les actions personnalisées.
- Icônes du cœur et du minuteur : `android/app/src/main/res/drawable/ic_media_*.xml` (vectoriels blancs 24 dp), gardés par `res/raw/keep.xml` (le rétrécissement des ressources de la version optimisée les supprimerait : `audio_service` les cherche par leur nom). Lecture, pause, précédent et suivant : icônes du système (Android 13+) ou d'`audio_service`.
- Un casque Bluetooth ou une voiture : « suivant » et « précédent » changent aussi de paysage (seulement pendant une écoute).

### 15.3 Arrêt et service au premier plan

Pendant la lecture, le service est au premier plan : la carte reste (non balayable). En pause, il quitte le premier plan (`androidStopForegroundOnPause`, `androidNotificationOngoing` désactivé) : la carte peut être **balayée**, ce qui arrête la séance (`onNotificationDeleted`, comme l'arrêt de l'application). Fin du minuteur, application balayée hors des récentes en pause : arrêt comme avant. Toucher la carte ouvre l'application.

**Toucher la carte sur l'écran verrouillé** (retour du product owner, Galaxy S24, 29 octobre 2026 : la carte se déploie, mais un second toucher ne demande pas de déverrouiller et n'ouvre pas l'application, contrairement à Spotify). Ce que montre la lecture du code d'`audio_service` 0.18.19 :

- l'intention « ouvrir l'application » n'est donnée à la session média que dans `enterPlayingState()`, **après** `mediaSession.setActive(true)` (`AudioService.java`, l. 705-711) : un lecteur du système qui lit `MediaController.getSessionActivity()` quand la session apparaît (lecteur de l'écran verrouillé et « Now Bar » de One UI, construits à partir des sessions actives) reçoit `null`, et aucun rappel ne l'avertit du changement ; la notification, elle, est construite juste après et porte bien l'intention (le volet des notifications ouvre l'application) ;
- cette intention n'existe que si `config.activityClassName` est connu (l. 396-409) : il n'est enregistré que si une activité est attachée au moment de `configure` ; un démarrage sans activité (démarrage programmé juste après l'installation) n'en a pas ;
- elle n'a ni `FLAG_ACTIVITY_NEW_TASK` ni, sur Android 14+, l'autorisation du créateur de lancer une activité depuis l'arrière-plan (Android 15+ ne la prête plus par défaut aux applications qui ciblent l'API 35 ou plus).

Correction (`MediaSessionLaunch.kt`) : `MainActivity` est inscrite dans les préférences d'`audio_service` avant tout démarrage de son service (`MainActivity.onCreate`, `ScheduleAlarmReceiver`) ; notre propre `PendingIntent` (activité `MainActivity`, `NEW_TASK | SINGLE_TOP`, immuable, `setPendingIntentCreatorBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)` sur Android 14+) est posé sur la session **dès que le service existe, avant sa première activation** (juste après `AudioService.init`, `lib/app/bootstrap.dart`), et à nouveau quand l'application revient ou passe en arrière-plan ; il remplace aussi l'intention statique d'`audio_service`, que chaque `enterPlayingState()` et chaque notification reprennent ensuite. `audio_service` n'exposant ni sa session ni cette intention, l'accès passe par réflexion sur trois champs, gardés par R8 (`proguard-rules.pro`) ; si un jour ces champs changent, l'application garde le comportement d'origine (journal `EventideMediaCard`). Cause probable, à confirmer sur le téléphone (§ 15.6, point 9) : aucun plantage ni journal du S24 n'était disponible.

### 15.4 Canal de notification et écran verrouillé

Canal `be.cinaf.eventide.playback`, nom « Lecture », description « Carte de lecture sur l’écran verrouillé et dans les notifications : paysage, minuteur et commandes du son », importance basse, sans pastille. Android garde le canal créé par une version précédente avec son ancien texte. Visibilité **publique** sur l'écran verrouillé (`audio_service` la pose sur sa notification `MediaStyle`, qui porte le jeton de session). Petite icône : `ic_notification` (goutte blanche) ; couleur d'accent opaque (`notificationColor`), utile à la barre de progression sur certains Android 12 et moins.

### 15.5 Code

- `lib/core/media_card.dart` : règles pures (`MediaCardInfo`, sous-titre du mix, paysage voisin, cycle et descriptions du minuteur).
- `lib/app/app_controller.dart` (section « Media card ») : calcule la carte à chaque changement du modèle (`PlaybackHost.mediaCard`), demande l'image, et répond aux boutons par les chemins de l'application (`skipLandscape` → `browseLandscape`, `toggleFavoriteFromCard`, `cycleTimerFromCard` → `setTimer`).
- `lib/services/audio/playback_handler.dart` : publie l'élément média (titre, sous-titre, image, durée) et l'état de lecture (boutons, position du minuteur, aucune action *seek*) ; envoie les boutons à l'hôte. `lib/services/audio/media_card_controls.dart` : boutons, icônes et indices compacts. `lib/services/audio/media_artwork.dart` : chaîne de l'image. `lib/ui/landscape/landscape_artwork.dart` : dessin hors écran.
- Tests : `test/core/media_card_test.dart`, `test/services/media_card_controls_test.dart`, `test/services/media_artwork_test.dart`, groupes « media card » de `test/services/playback_handler_test.dart` et `test/app/app_controller_test.dart`, et `test/ui/landscape_video_test.dart` (les boutons de la carte ne touchent jamais la vidéo).

### 15.6 À vérifier sur le Galaxy S24 (One UI 6 à 8, Android 14 à 16)

1. Écran verrouillé, carte **repliée puis déployée** : image du paysage (affiche pour Cascade en forêt, dessin pour un paysage sans affiche), titre, sous-titre du mix, barre qui avance, boutons précédent/lecture-pause/suivant/cœur/minuteur, icônes nettes et blanches.
2. Barre : 15 min de minuteur → la barre fait 15 min ; pause → elle s'arrête ; reprise → elle repart d'où elle était ; toucher le minuteur → elle repart de 0 avec la nouvelle durée ; « Sans minuteur » → plus de barre ; la barre ne se laisse pas déplacer au doigt.
3. Suivant / précédent écran verrouillé : la carte change tout de suite, le son ~1,5 s après, la mélodie monte ; au bord du thème le bouton disparaît (gratuit : seulement Cascade en forêt ↔ Sous-bois ensoleillé) ; en rouvrant l'application, l'Accueil montre le nouveau paysage.
4. Cœur : se remplit et se vide ; gratuit avec 3 favoris : rien ne se passe ; dans l'application, l'écran Favoris est à jour.
5. Pause depuis la carte, application ouverte : la vidéo du paysage continue. En pause, balayer la carte : le son s'arrête et la carte disparaît ; pendant la lecture, elle ne se balaie pas.
6. **Always On Display** (informations musicales), volet des notifications, « Now Bar » (One UI 7+), **Sortie média** / Bluetooth : titre, sous-titre et boutons ; casque Bluetooth : suivant/précédent changent de paysage.
7. TalkBack : chaque bouton est lu en français (« Paysage suivant », « Minuteur 30 min. Toucher pour 1 h »…).
8. Version optimisée (*release*) : les icônes du cœur et du minuteur s'affichent (rétrécissement des ressources).
9. **Toucher la carte écran verrouillé** (déployée, puis toucher l'image ou le titre ; aussi dans la « Now Bar » et sur l'Always On Display) : One UI demande de déverrouiller, puis l'application s'ouvre sur l'Accueil, le son continue. À refaire application balayée hors des récentes (son en cours), puis après un démarrage programmé. Si rien ne se passe : `adb shell dumpsys media_session` doit montrer pour `be.cinaf.eventide.demo` une ligne `launchIntent=PendingIntent{…}` (et non `null`) ; `adb logcat -s EventideMediaCard` doit montrer `media card opens the app: installed=true` ; pendant le toucher, `adb logcat | grep -i "background activity"` ne doit montrer aucun blocage.

## 16. Rapport de problème

Retour du product owner (29 octobre 2026) : l'application s'est arrêtée au bout d'environ 30 minutes sur le Galaxy S24, sans aucune donnée de plantage. Le rapport est **gardé sur le téléphone**, sans service externe, sans compte, sans donnée personnelle ; il ne part que si l'utilisateur le partage.

### 16.1 Ce qui est relevé

- **Arrêts relevés par Android** (`ExitReports.kt`, Android 11+) : `ActivityManager.getHistoricalProcessExitReasons` pour notre paquet (application et processus `:wallpaper`) : raison (plantage Java/Kotlin, plantage natif, ANR, mémoire insuffisante, trop de ressources, tuée par un signal, par le système, par l'utilisateur, mise à jour…), date, état du processus à ce moment (premier plan, service au premier plan, en arrière-plan…), mémoire PSS/RSS, description d'Android ; pour un ANR, le début de la trace (24 Ko, le fil principal vient en premier) ; pour un plantage natif, les chaînes lisibles de la *tombstone* (format protobuf depuis Android 12, 24 Ko). Chaque arrêt n'est donné qu'une fois (horodatage du dernier vu gardé) ; l'application garde les 12 derniers (`diagnostics/exits.json`), les traces sur les 3 plus récents.
- **Arrêt anormal** : plantage, plantage natif, ANR, échec au démarrage toujours ; arrêt par le système (mémoire, ressources, signal, autre) seulement si l'application était **utilisée** (à l'écran, son en cours, fond d'écran visible) : Android arrête couramment les processus inactifs en arrière-plan, ce n'est pas un problème.
- **Journal de l'application** (`lib/services/diagnostics.dart`, `diagnostics/log.txt` puis `log.1.txt`, 160 Ko chacun au plus) : erreurs Flutter (`FlutterError.onError`) et erreurs Dart non rattrapées (`PlatformDispatcher.onError`), **toujours transmises ensuite aux gestionnaires d'avant** (elles restent écrites dans logcat, ce que vérifie la CI) ; pas de zone gardée, qui les cacherait à logcat. Repères pour un arrêt au bout de 30 minutes : démarrage (version, démo), paysage affiché, ouverture et libération des lecteurs vidéo (avec leur nombre), état du son (lecture, pause, arrêt), début d'écoute (paysage, minuteur) et **fin d'écoute avec sa raison** (fin du minuteur, arrêt, nuit), état de l'application (premier plan, arrière-plan), mémoire du processus (RSS) toutes les 5 minutes. Un message répété n'est écrit qu'une fois avec son nombre ; 120 lignes par minute au plus. Les adresses électroniques et la partie « requête » des URL (signatures des liens de contenu) sont masquées.

### 16.2 Interface

Réglages › Compte › **« Signaler un problème »** : sous-titre « Dernier arrêt anormal : Plantage natif (moteur, son ou vidéo), le 29 octobre à 22 h 14 » s'il y en a un, sinon « Envoyer un rapport technique, sans donnée personnelle ». Le toucher ouvre la feuille de partage d'Android avec le rapport en texte brut : version de l'application, Android, modèle du téléphone et sa mémoire, arrêts relevés (le plus récent d'abord) avec leurs traces, puis les 400 dernières lignes du journal. Ni compte, ni identifiant (pas d'Android ID), ni historique d'écoute. La suppression des données efface aussi le journal et les arrêts gardés.

### 16.3 Code

`lib/core/problem_report.dart` (raisons, règle « anormal », résumé, texte du rapport), `lib/services/diagnostics.dart` (`DiagnosticsLog`, `Breadcrumbs`, `installErrorHooks`, `SessionBreadcrumbs`, `ProblemReports`, canal `be.cinaf.eventide/device`), `main.dart` (installation des gestionnaires), `bootstrap.dart` (dossier du journal, repères), `AppModel.lastAbnormalExit` et `shareProblemReport()` (valeurs par défaut concrètes : les faux n'ont rien à implémenter). Natif : `ExitReports.kt`, `DevicePlugin.kt`. Tests : `test/core/problem_report_test.dart`, `test/services/diagnostics_test.dart`, `test/app/report_wallpaper_test.dart`, `test/ui/report_wallpaper_screens_test.dart`.

### 16.4 Pistes pour l'arrêt au bout de 30 minutes, et ce qu'il faut vérifier sur le S24

- **Ce n'est peut-être pas un plantage** : avec un minuteur de 30 min (bouton minuteur de la carte : 15 → 30 → 1 h…), le son baisse pendant 30 s puis s'arrête et la carte disparaît, ce qui peut ressembler à un arrêt de l'application. Le rapport le dit désormais (« écoute arrêtée : timer après 30 min d'écoute »).
- Sinon, le rapport donnera la raison exacte. Si c'est « mémoire insuffisante » ou un plantage natif avec une mémoire (PSS/RSS) élevée, et si les repères « mémoire » montrent une hausse régulière pendant que la vidéo tourne, la piste est une fuite par image dans la chaîne vidéo (ExoPlayer → `SurfaceProducer` → Impeller/Vulkan) : 24 images/s pendant 30 min font 43 000 images, une petite fuite par image suffit.
- À faire sur le S24 : (1) installer la nouvelle démo ; (2) refaire 30 à 40 minutes comme la première fois (même paysage, même minuteur), sans brancher le téléphone ; (3) Réglages › « Signaler un problème » : lire le sous-titre, puis partager le rapport (courriel à soi-même) et le transmettre ; (4) si possible, avant de rouvrir l'application après l'arrêt : `adb shell dumpsys activity exit-info be.cinaf.eventide.demo`, et `adb bugreport` (il contient les *tombstones* complètes).

## 17. Fond d'écran vidéo

Demande du product owner (29 octobre 2026) : proposer de faire de la vidéo du paysage un fond d'écran.

### 17.1 Fond d'écran animé (Android)

- **Service** `LandscapeWallpaperService` (`WallpaperService`, permission `BIND_WALLPAPER`, méta-données `res/xml/landscape_wallpaper.xml` : nom « Eventide · paysage vivant », description en français, vignette = icône) dans **son propre processus** `:wallpaper` : il vit tant que le fond d'écran est en place, sans le moteur Flutter de l'application, et un incident chez lui n'arrête jamais le son.
- Vidéo du paysage choisi en boucle **sans raccord** (ExoPlayer de Media3 1.9.2, la même version que `video_player_android`, déclarée explicitement ; `REPEAT_MODE_ALL`), **muette** (piste audio désactivée : rien n'est décodé, aucun focus audio), recadrée au centre pour remplir l'écran (`VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING`, fait par le décodeur).
- **Batterie** : en pause dès que le fond d'écran n'est plus visible (une application par-dessus, écran éteint) ; décodeur libéré après 15 s cachée (il revient au même endroit) ; tout est libéré quand la surface disparaît.
- **Image fixe** (l'image 0 de la boucle, recadrée au centre, sur le fond sombre de l'application) si la vidéo manque, ne se décode pas, ou si la formule ne permet plus ce paysage (Premium terminé : l'application prévient le service à chaque changement de formule). Une surface dessinée au `Canvas` ne peut plus recevoir de décodeur vidéo (Android la garde reliée au processeur) : la vidéo revient à la surface suivante (aperçu, redémarrage, fond d'écran remis).
- **Choix** : l'application copie la vidéo et l'image embarquées dans son dossier (`files/wallpaper/<id>.mp4|.jpg`, seulement celles du paysage choisi) ou réutilise les fichiers téléchargés pour Premium (`files/content/…`), écrit la sélection (`files/wallpaper_selection.json`, relue par le service à chaque fois qu'il devient visible ; seuls des fichiers de l'application sont lus), puis ouvre l'aperçu d'Android (`WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER` avec notre composant, sinon la liste des fonds d'écran animés) : **l'utilisateur confirme**, Android ne laisse jamais une application changer le fond d'écran en silence. Seulement pour un paysage que la formule permet ; dans la démo, tous. « Réduire les animations » ne change rien : c'est un choix explicite de l'utilisateur, la vidéo se met seulement en pause quand elle est cachée.

### 17.2 Galerie (écran verrouillé One UI)

« Enregistrer dans la Galerie » copie la vidéo dans `Movies/Eventide` par MediaStore (Android 10+, **sans autorisation** ; caché en dessous). Utile pour l'écran verrouillé des Samsung, qui n'accepte qu'une vidéo de la Galerie et **environ 15 secondes au plus** (dit dans l'interface). Une copie faite seulement pour la Galerie n'est pas gardée dans l'application.

### 17.3 Interface

Paysages › **« Fond d'écran »** (sous la grille, pour le paysage sélectionné ; seulement si le téléphone permet un fond d'écran animé ou la Galerie) → feuille « Fond d'écran » : « Mettre en fond d'écran (vidéo animée) » (« Le paysage bouge doucement sur l'écran d'accueil, sans aucun son. Android affiche un aperçu : touchez « Définir comme fond d'écran » pour confirmer. Sur l'écran verrouillé, cela dépend du téléphone… ») et « Enregistrer dans la Galerie » (explication Samsung et 15 secondes). Paysage sans vidéo : son image fixe ; paysage Premium en gratuit : « Découvrir Premium ». L'entrée est dans Paysages plutôt que dans le menu de l'Accueil (modifié en parallèle par le retrait de la voix).

### 17.4 Code

`lib/core/wallpaper.dart`, `lib/services/wallpaper_service.dart` (`LandscapeWallpaper`, canal `be.cinaf.eventide/device`), `AppModel.wallpaperSupport`, `setLandscapeWallpaper`, `saveLandscapeVideoToGallery` (valeurs par défaut concrètes), `lib/ui/screens/wallpaper_sheet.dart`, entrée dans `landscapes_sheet.dart`. Natif : `LandscapeWallpaperService.kt`, `WallpaperStore.kt` (sélection, `LiveWallpaper`, `GallerySaver`), `DevicePlugin.kt`, manifeste (`uses-feature android.software.live_wallpaper` non requis). Tests : `test/services/wallpaper_service_test.dart`, `test/app/report_wallpaper_test.dart`, `test/ui/report_wallpaper_screens_test.dart`. Le Kotlin n'a pas pu être compilé ici (pas de SDK Android ni d'accès à Google Maven) : la CI (`flutter build apk --debug`) le compile.

### 17.5 À vérifier sur le Galaxy S24

1. Paysages › Fond d'écran › « Mettre en fond d'écran » : l'aperçu d'Android montre la vidéo qui bouge, recadrée sans bandes noires ; « Définir comme fond d'écran » (écran d'accueil, et écran verrouillé si One UI le propose).
2. Écran d'accueil : boucle sans accroc ni image noire au raccord ; aucun son ; la musique d'Eventide (ou d'une autre application) n'est jamais interrompue.
3. Ouvrir une application par-dessus, éteindre l'écran : la vidéo s'arrête (*Paramètres › Batterie* : consommation d'« Eventide Démo » faible après une nuit) ; au retour elle reprend.
4. Changer de paysage depuis l'application et le remettre en fond d'écran : le nouveau paysage apparaît.
5. Désinstaller puis réinstaller, ou effacer les données : le fond d'écran n'empêche rien (Android revient au fond par défaut ou montre un fond sombre).
6. « Enregistrer dans la Galerie » : la vidéo apparaît dans Galerie › Movies/Eventide ; *Paramètres › Fond d'écran › Écran verrouillé* l'accepte (après découpe éventuelle à 15 s).
7. Version *release* (R8) : tout ce qui précède, et la carte de lecture (§ 15.6, point 9).

