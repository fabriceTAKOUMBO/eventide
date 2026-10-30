# Architecture de l'application Eventide (Flutter, Android)

Ce document décrit la couche applicative (`app/lib/app`), les services (`app/lib/services`) et le code natif Android (`app/android`). L'interface (`app/lib/ui`) et le domaine pur (`app/lib/core`) ont leurs propres conventions ; le contrat serveur est dans [`../api/contrat-v1.md`](../api/contrat-v1.md).

## 1. Modules

| Dossier | Rôle | Dépend de |
|---|---|---|
| `lib/core/` | Domaine pur, sans Flutter ni plugin : catalogue, document de scène, programmations, réglages, formules et droits (`ProductRules`), codec de partage, nuits, garde-fou contre les plantages en boucle (§ 19) | rien |
| `lib/app/app_model.dart` | **Contrat entre l'interface et l'application** (`AppModel`, événements) | `core` |
| `lib/app/app_controller.dart` | `RealAppModel` : enchaîne les règles du domaine avec le stockage, l'audio, le réseau, les achats, la publicité et les démarrages programmés | `core`, `services` |
| `lib/app/bootstrap.dart` | Construit les services réels, dans le bon ordre (voir § 4) | tout |
| `lib/app/env.dart` | Configuration par `--dart-define` (§ 10) | — |
| `lib/app/demo_mode.dart` | Décisions de la version démo (§ 12) | `core` |
| `lib/app/sleep_tracker.dart` | Suivi du sommeil, méthode 1 du dossier (§ 9) | `core` |
| `lib/services/` | Accès à la plateforme, chacun derrière une interface remplaçable par un faux dans les tests | plugins |
| `lib/ui/` | Écrans « Vitre » ; ne connaît que `AppModel` et `core` | `app_model.dart`, `core` |
| `android/app/src/main/kotlin/` | Alarmes exactes, récepteurs, notifications de secours, Play Integrity, canal `be.cinaf.eventide/native` ; canal `be.cinaf.eventide/device` (`DevicePlugin` : rapport de problème § 16, intention de la carte de lecture § 15.3, fond d'écran § 17) ; service de fond d'écran animé (`LandscapeWallpaperService`, processus `:wallpaper`) | — |

Services : `storage.dart` (fichiers JSON), `api_client.dart` (API, jeton d'installation), `connectivity.dart`, `content_repository.dart` (sons, vidéos et images de paysages : embarqués, cache, téléchargements), `audio/` (moteur, focus, service de lecture), `billing_service.dart`, `ads_service.dart`, `account_service.dart`, `links_service.dart` (feuille de partage, App Links, pages externes par `url_launcher`), `permissions_service.dart`, `native_bridge.dart`, `diagnostics.dart` (rapport de problème, § 16), `wallpaper_service.dart` (fond d'écran, § 17).

## 2. Flux de données

- L'interface appelle `AppModel` et écoute ses notifications (`ChangeNotifier`) et ses événements ponctuels (`events` : ouvrir Premium, Hors connexion, Veille, message…).
- **Le téléphone d'abord.** Tout l'état vit dans de petits fichiers JSON versionnés (`{"version": 1, "data": …}`) du dossier de support de l'application : `scene`, `schedules`, `favorites`, `settings`, `nights`, `entitlements`, `installation`, `app_state`. Chaque écriture est atomique (fichier temporaire, `flush`, renommage) et les écritures d'un même fichier sont mises en file. La scène est enregistrée 0,4 s après le dernier changement (curseurs), et immédiatement quand l'application passe en arrière-plan.
- Le serveur n'est appelé que pour une raison : installation (une fois), droits (au lancement si en ligne, après un achat), achats, liens de partage courts, adresses signées de contenu Premium, compte, export et suppression.
- « En ligne » veut dire qu'une vraie requête a réussi (`GET <API>/health`, puis `https://connectivitycheck.gstatic.com/generate_204`) ; `online` ne passe à faux qu'après un échec réel. Une panne de l'API seule ne bloque jamais un utilisateur gratuit.

## 3. Lecture audio

- **Moteur** (`SoLoudAudioEngine`, `flutter_soloud` 5) : une voix en boucle par couche (sons et musiques ; les décors sont visuels), plus, de temps en temps, un **événement** joué une seule fois par-dessus (un coup de tonnerre : `playEvent`, § 18). Volume d'une couche = niveau / 100 × gain de catégorie (musique 0,8). Le volume global porte le plafond (0,85), la montée progressive, l'atténuation (*duck*), les fondus de pause et le fondu de fin.
- Les fichiers sont **lus depuis le disque** (`LoadMode.disk`) : décodée en mémoire, une boucle stéréo pèse environ 18 Mo pour 47 s ; six couches sur toute une nuit seraient trop lourdes pour un téléphone d'entrée de gamme. Les boucles fournies se raccordent à l'échantillon près dans ce mode.
- Départ de chaque couche à un endroit tiré au hasard (`seek`), longueurs de boucle différentes (23 à 47 s), légère variation lente et aléatoire du volume (± 7 % sur 20 s) : pas de répétition audible.
- Changement de paysage : fondu enchaîné de 2 s (une couche commune aux deux paysages glisse simplement vers son nouveau niveau). Changement de niveau : 0,4 s.
- **Mélodie de départ** : chaque paysage commence avec une musique douce et basse (15 à 25 %, `mix.musique` du catalogue ; mélodies gratuites pour les paysages gratuits). Elle **entre progressivement en 20 s** (`MixRules.musicEntry`) quand l'écoute part du silence (bouton lecture, notification, démarrage programmé) et quand le mix change de paysage (glissement, grille, favori, lien de partage) ; les sons de nature gardent leur fondu (2 s). Une musique ajoutée ou réglée à la main, ou remise après une sourdine, revient en 1 s. Pour un démarrage programmé, la montée du volume global (`montee_minutes`) s'applique en plus : les deux gains se multiplient et ne dépassent jamais le niveau voulu. Après une pause, la musique revient en 3 s (`musicResume`), les sons avec le fondu global de 0,4 s. Le contrôleur décide (`EngineLayer.fadeIn`, `resumeFade`), le moteur exécute.
- **Sourdine** (« Sons de nature » et « Musique », contrat § 1) : couper une catégorie garde ses couches et leurs niveaux ; le volume de ses voix descend à 0 en 1 s, puis chaque voix est **mise en pause** (« garée ») ; la remettre relance la voix là où elle était et la refait monter en 1 s depuis le silence, sans raccord audible. Choix mesuré : une voix à volume 0 qui continue de tourner est toujours décodée et mixée par SoLoud (il ne saute que les voix au-delà de sa limite de 16) ; décoder une boucle Opus 48 kHz stéréo coûte environ 0,45 % d'un cœur de PC de bureau (mesuré avec `ffmpeg -benchmark`), plusieurs fois plus sur le petit cœur d'un téléphone d'entrée de gamme, toute la nuit, pour rien. Tout en sourdine : toutes les voix sont garées, le moteur est muet comme en pause (la sortie audio reste ouverte), mais la séance continue : minuteur, notification, et **la vidéo du paysage, jamais liée à l'état du son**. Un démarrage où tout serait en sourdine remet les deux catégories (un démarrage n'est jamais muet) ; une reprise après pause garde la sourdine. Toucher un niveau d'une catégorie en sourdine (curseur, − / +, ajout) la remet. La sourdine est enregistrée avec la scène, gardée au changement de paysage, jamais mise dans un favori ni un partage.
- **Pas de sortie audio** (émulateur sans son, pilote audio en panne) : l'ouverture du périphérique échoue ou ne répond pas en 15 s, le démarrage échoue proprement, le lecteur revient à l'arrêt et l'application affiche « Le son ne peut pas démarrer pour le moment » ; l'interface reste utilisable.
- **Service au premier plan** : `PlaybackHandler` (`audio_service`, type `mediaPlayback`) porte le moteur, la carte de lecture de l'écran verrouillé et des notifications (§ 15) et **le minuteur**, qui continue donc quand l'application est fermée. Fin du minuteur : fondu de 30 s, arrêt complet, l'écran n'est pas rallumé. « Toute la nuit » s'arrête après `limites.nuit_max_heures` (10 h). Le décompte est gelé pendant une pause.
- **Focus audio** (`audio_session`) : appel ou autre lecteur → pause, reprise automatique si l'interruption était passagère ; GPS ou notification → volume baissé ; casque débranché → pause. Balayer l'application hors des récentes laisse le son et son minuteur continuer.
- Le gratuit exige une connexion : avant de **démarrer** un son, un utilisateur gratuit fait une vraie vérification réseau (au plus une toutes les 2 minutes). Une écoute déjà en cours n'est jamais coupée ; seul le chargement d'un nouveau paysage ou d'un nouveau son est refusé hors connexion.
- **Contenus** (`ContentRepository`) : fichier embarqué `assets/audio/<sons|musiques>/<id>.ogg` s'il existe (éléments gratuits), sinon fichier déjà téléchargé, sinon téléchargement (adresse CloudFront signée par `POST /content/urls`, ou serveur local en debug). Jamais un fichier absent du serveur : `assets/landscapes/remote.json` liste aussi les sons et musiques présents sur S3 (`isPublished`, § 18). Pour Premium, tous les sons et musiques sont téléchargés en arrière-plan, un par un, en Wi-Fi seulement si le réglage est activé, puis les images fixes des paysages (les vidéos sont téléchargées quand leur paysage est affiché, § 14).

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

## 5. Voix (retirée)

Plus de micro ni d'assistant vocal depuis le 29 octobre 2026 (décision du product owner) : voir le [contrat, § 3 et § 7](../api/contrat-v1.md).

## 6. Achats et droits

`in_app_purchase` (Billing Library 9) : abonnement `eventide_premium` (`monthly`, `annual` avec essai de 3 jours) et achat unique `eventide_lifetime`. Les prix viennent de Google Play (prix récurrent de l'offre, essai détecté par une première phase à 0) ; les prix du dossier ne servent qu'à l'affichage quand Play ne répond pas. Chaque achat part à `POST /purchases`, qui le vérifie et l'acquitte. Sans réponse du serveur, l'achat n'est pas acquitté : Google le représente, « Restaurer mes achats » relance la vérification.

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
| `API_BASE_URL` | vide | URL de l'API, par exemple `https://api.eventide.app/v1`. Vide : aucun serveur, achats non vérifiés (debug) |
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
| `release-apks` | Versions *release* (R8) de production puis de démo, arm64-v8a et x86_64, signées avec la clé de debug ; l'APK de production n'a **aucun** son Premium (`assets/flutter_assets/assets/audio/sons/vagues.ogg` absent ; ni l'ambiance Premium ni les variantes du tonnerre), **aucune** vidéo ni image de paysage Premium (`content/videos`, `content/images`) ni aucun fichier de `medias-test/` (ambiance de test comprise), mais la vidéo gratuite `cascade-foret` et son ambiance ; paquet `be.cinaf.eventide`, nom « Eventide » ; l'APK de démo a tous les sons et musiques de `content/audio`, toutes les vidéos et images de `content/` et de `medias-test/`, l'ambiance de test de `medias-test/audio`, paquet `be.cinaf.eventide.demo`, nom « Eventide Démo » (`app/tool/ci/check_apk_contents.sh`) | `eventide-demo-galaxy-s24-arm64` (à installer sur le téléphone), `eventide-demo-emulator-x86_64`, `eventide-production-release-apks-debug-signed` |
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
- Achats en test interne Google Play (essai de 3 jours, restauration, remboursement), consentement publicitaire depuis l'Europe, App Links vérifiés une fois le domaine acheté, TalkBack et police à 200 %.
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

- **Ce qui change** : droits forcés à la formule annuelle (Premium), quel que soit le cache ; aucun appel au serveur pour les droits ; aucune publicité (`NoAdsService`) ; aucun appel à Google Play (`DemoBilling`) : l'écran Premium dit « Version démo : Premium est déjà actif », ses boutons sont désactivés, « Restaurer mes achats » répond par un message, « Gérer mon abonnement » n'existe pas ; écoute hors connexion et programmations sans limite ; mention discrète « Version démo » en bas de Réglages.
- **Sons et paysages Premium embarqués** : la CI (`app/tool/ci/bundle_demo_media.sh`) copie `content/audio/sons/*.ogg` et `content/audio/musiques/*.ogg` dans `app/assets/audio/`, `content/videos/paysages/*.mp4` et `content/images/paysages/*.jpg` dans `app/assets/landscapes/` **avant** la construction de la démo seulement ; `ContentRepository` préfère les fichiers embarqués. La CI vérifie que l'APK de production n'en contient aucun.
- **Matériel de test non diffusable** : les vidéos de tiers de `medias-test/` (YouTube, tests internes du product owner : `toits-pluie`, `ciel-etoile`) et l'ambiance tirée de la bande son de `toits-pluie` (`medias-test/audio/sons/ambiance-toits-pluie.ogg`) sont copiées de la même façon, dans la démo seulement ; elles sont à retirer avant toute bêta, même fermée (`medias-test/LISEZMOI.md`, `content/LICENCES.md`). La version de production ne demande jamais cette ambiance (absente de `remote.json`) : elle est simplement laissée de côté dans le mix de `toits-pluie`.

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

**Ce que fait la démo** : tous les paysages, sons, musiques et décors (sons Premium dans l'APK, écoute sans connexion), programmations sans limite, minuteur, Veille, sommeil, partage par lien autonome, sans publicité.
**Ce qu'elle ne fait pas** : aucun achat ni restauration (l'écran Premium dit « Version démo : Premium est déjà actif »), aucun serveur (pas de compte Google relié, pas de lien de partage court), pas de mise à jour par Google Play.

**Réglages Samsung pour les programmations** (sinon One UI peut endormir l'application et le son ne démarre pas à l'heure) :

- *Paramètres* → *Applications* → *Eventide Démo* → *Batterie* → **Non restreinte**.
- *Paramètres* → *Batterie* (ou *Entretien de l'appareil* → *Batterie*) → *Limites d'utilisation en arrière-plan* : Eventide Démo ne doit figurer ni dans **Applications en veille** ni dans **Applications en veille prolongée** (« veille profonde ») ; l'ajouter aux **Applications jamais mises en veille** et, au besoin, désactiver « Mettre en veille les applications inutilisées ».
- *Paramètres* → *Applications* → *Eventide Démo* → **Alarmes et rappels** : autorisé (la carte « Autoriser » de l'écran Programmations y mène) ; **Notifications** : autorisées (rappel et commandes du son).
- Test rapide : programmer un départ dans 5 minutes, verrouiller l'écran, attendre. Le son doit démarrer avec sa notification ; sinon une notification « C’est l’heure… » avec « Lancer » apparaît (Android a refusé le démarrage en arrière-plan) : revoir les réglages de batterie ci-dessus.

## 14. Paysages vivants (vidéos)

Le paysage plein écran (Accueil, Bienvenue, Hors connexion) est un **paysage vivant** : une courte vidéo en boucle, muette, fondue dans l'interface. Exigence du product owner : elle ne doit **jamais** donner l'impression d'une vidéo ni d'un lecteur.

- **Chaîne de priorité** (`LandscapeBackground`, `lib/ui/landscape/landscape_background.dart`) : vidéo (si le paysage en a une, que la formule l'autorise et qu'elle peut être lue maintenant) → image fixe (l'image 0 de la boucle) ou photo → dessin procédural. Même cadrage (`BoxFit.cover`, plein écran sous les panneaux de verre), même filtre de moment de la journée, même flou ; le décor et les panneaux restent au-dessus ; l'image suit le doigt pendant un balayage comme avant. Le mouvement lent (*Ken Burns*) ne s'applique qu'aux images fixes des paysages **sans** vidéo : l'image fixe d'un paysage vidéo reste exactement là où la vidéo apparaîtra.
- **Jamais de lecteur visible** : pas de commandes, pas de roue d'attente, jamais d'image noire. L'image fixe est la première image de la boucle encodée (`tools/media/process_video.py`) ; elle reste affichée tant que la vidéo n'a pas produit ses premières images (lecture en cours et position qui avance), puis la vidéo apparaît par-dessus en 0,24 s, identique au pixel près. Boucle sans raccord dans le fichier (fondu enchaîné, mesures dans `tools/media/README.md`) et lecture en boucle d'ExoPlayer (`REPEAT_MODE_ALL`, sans coupure entre deux tours).
- **Jamais liée au son** : lecture/pause (bouton, notification, perte du focus audio, fin du minuteur) et sourdine ne changent que le son ; aucun chemin commun entre l'état du son et la vidéo (`LandscapeBackground` ne lit jamais `AppModel.playing`, testé). La vidéo ne demande jamais le focus audio (`mixWithOthers`), sinon elle mettrait en pause le son de l'application, et elle n'a pas de piste son.
- **Le son du paysage est le sien** (depuis le 29 octobre 2026, § 18) : la bande son d'origine de la vidéo, sans tonnerre, est l'**ambiance** du paysage, un son du catalogue joué par le mélangeur en tête du mix par défaut (et non plus seulement des sons génériques synthétiques). Les éclairs ne sont plus dans la vidéo (effacés par `process_video.py`) : le décor « Éclairs lointains » les dessine, juste avant chaque tonnerre.
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
- **Image** : le paysage, en fichier local (`audio_service` n'accepte que `file://` et `content://`). Dans l'ordre : l'image fixe embarquée `assets/landscapes/<id>.jpg`, copiée une fois dans le cache (`media_art/<id>-<empreinte>.jpg`, nommée d'après son contenu : jamais d'image périmée après une mise à jour) ; sinon l'image téléchargée pour Premium (`images/paysages/<id>.jpg`) ; sinon le **dessin procédural** du paysage au moment de la journée, rendu hors écran en PNG carré 720 × 720 (`media_art/<id>-<moment>-v2.png`, `-v2-s.png` pour un dessin simplifié, § 19). L'image suit le paysage et, pour le dessin, le moment. Elle n'est fabriquée que pendant une écoute, **jamais avant le son** et **jamais pendant un balayage** : la carte (titre, sous-titre) suit tout de suite, l'image vient quand le son suit le paysage (1,5 s) ; un dessin à la fois (§ 19). La carte est publiée d'abord, l'image ajoutée quand elle est prête (le dessin est abandonné après 10 s, par exemple sans processeur graphique). Android peut vider le cache : les fichiers sont refaits.
- **Barre de progression = minuteur** : durée = longueur du minuteur (« Toute la nuit » : `limites.nuit_max_heures`, 10 h) ; position = temps écoulé depuis le départ du minuteur, figée pendant une pause, **repartie de 0** quand le minuteur change ; pleine pendant le fondu de fin. Le système fait avancer la barre lui-même (position, vitesse 1, heure de mise à jour). « Sans minuteur » : pas de durée, donc pas de barre. La barre est **informative** : aucune action « déplacer » (*seek*) n'est proposée et une demande de déplacement est ignorée.

### 15.2 Boutons (déployée : jusqu'à 5 ; repliée : lecture/pause et suivant)

| Bouton | Effet | Description (TalkBack) |
|---|---|---|
| Paysage précédent / suivant | Paysage voisin **dans le thème**, les paysages verrouillés pour la formule sont sautés, **pas de boucle** : bouton absent au bord. Même chemin qu'un balayage de l'Accueil : la carte change tout de suite, le son suit après 1,5 s (plusieurs touchers rapides : seul le dernier paysage est chargé) avec le mix par défaut et la mélodie qui monte en 20 s ; l'Accueil et sa vidéo suivent si l'application est visible ; jamais un paysage verrouillé | « Paysage précédent », « Paysage suivant » |
| Lecture / pause | **Le son seulement**, comme partout : la vidéo du paysage n'est jamais liée à l'état du son | « Lecture », « Pause » |
| Cœur | Ajoute ou retire la scène des favoris (rempli si elle en est un), sans message. À la limite gratuite (3 favoris) : rien, le cœur reste vide ; l'application propose Premium quand on l'ouvre. Pendant un précédent/suivant en attente, le paysage montré est d'abord chargé | « Ajouter aux favoris », « Retirer des favoris » |
| Minuteur | 15 min → 30 min → 1 h → 2 h → Toute la nuit → Sans minuteur → 15 min (une durée hors cycle, venue d'une scène enregistrée, passe à l'étape suivante). L'icône montre l'état actuel (« 15 », « 30 », « 1h », « 2h », lune, minuteur barré) | « Minuteur 30 min. Toucher pour 1 h », « Minuteur toute la nuit. Toucher pour l’enlever », « Sans minuteur. Toucher pour 15 min » |

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
- **Journal de l'application** (`lib/services/diagnostics.dart`, `diagnostics/log.txt` puis `log.1.txt`, 160 Ko chacun au plus) : erreurs Flutter (`FlutterError.onError`) et erreurs Dart non rattrapées (`PlatformDispatcher.onError`), **toujours transmises ensuite aux gestionnaires d'avant** (elles restent écrites dans logcat, ce que vérifie la CI) ; pas de zone gardée, qui les cacherait à logcat. Repères pour un arrêt au bout de 30 minutes : démarrage (version, démo), paysage affiché, ouverture et libération des lecteurs vidéo (avec leur nombre), état du son (lecture, pause, arrêt), début d'écoute (paysage, minuteur) et **fin d'écoute avec sa raison** (fin du minuteur, arrêt, nuit), état de l'application (premier plan, arrière-plan), mémoire du processus (RSS) toutes les 5 minutes ; **avant chaque dessin hors écran** d'un paysage procédural (« dessin : paysage lisiere 672×1456 ») ou de l'image de la carte (« dessin : image de la carte lisiere 720×720 nuit »), ligne écrite sur-le-champ (synchrone, `addDurable`) pour survivre à un plantage natif ; au lancement suivant, ce que le garde-fou a trouvé (§ 19). Un message répété n'est écrit qu'une fois avec son nombre ; 120 lignes par minute au plus. Les adresses électroniques et la partie « requête » des URL (signatures des liens de contenu) sont masquées.

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

### 17.2 Galerie (retirée)

La copie dans la Galerie (« Enregistrer dans la Galerie ») est **retirée** le 29 octobre 2026 (décision du product owner) : sur le Galaxy S24, le fond d'écran animé fonctionne sur l'écran d'accueil **et** sur l'écran verrouillé de One UI. Plus de bouton, de méthode de canal ni de code MediaStore.

### 17.3 Interface

Paysages › **« Fond d'écran »** (sous la grille, pour le paysage sélectionné ; seulement si le téléphone permet un fond d'écran animé) → feuille « Fond d'écran » : bouton **« Fond d'écran animé »** (sur une seule ligne sur le S24, 384 dp de large ; l'ancien libellé « Mettre en fond d'écran (vidéo animée) » passait sur deux lignes), avec l'explication dessous (« Le paysage bouge doucement sur l'écran d'accueil, sans aucun son. Android affiche un aperçu : touchez « Définir comme fond d'écran » pour confirmer. Sur l'écran verrouillé, cela dépend du téléphone… »). Paysage sans vidéo : « Mettre en fond d'écran » avec son image fixe ; paysage Premium en gratuit : « Découvrir Premium ». L'entrée est dans Paysages plutôt que dans le menu de l'Accueil (modifié en parallèle par le retrait de la voix).

### 17.4 Code

`lib/core/wallpaper.dart`, `lib/services/wallpaper_service.dart` (`LandscapeWallpaper`, canal `be.cinaf.eventide/device`), `AppModel.wallpaperSupport`, `setLandscapeWallpaper` (valeurs par défaut concrètes), `lib/ui/screens/wallpaper_sheet.dart`, entrée dans `landscapes_sheet.dart`. Natif : `LandscapeWallpaperService.kt`, `WallpaperStore.kt` (sélection, `LiveWallpaper`), `DevicePlugin.kt`, manifeste (`uses-feature android.software.live_wallpaper` non requis). Tests : `test/services/wallpaper_service_test.dart`, `test/app/report_wallpaper_test.dart`, `test/ui/report_wallpaper_screens_test.dart`. Le Kotlin n'a pas pu être compilé ici (pas de SDK Android ni d'accès à Google Maven) : la CI (`flutter build apk --debug`) le compile.

### 17.5 À vérifier sur le Galaxy S24

1. Paysages › Fond d'écran › « Mettre en fond d'écran » : l'aperçu d'Android montre la vidéo qui bouge, recadrée sans bandes noires ; « Définir comme fond d'écran » (écran d'accueil, et écran verrouillé si One UI le propose).
2. Écran d'accueil : boucle sans accroc ni image noire au raccord ; aucun son ; la musique d'Eventide (ou d'une autre application) n'est jamais interrompue.
3. Ouvrir une application par-dessus, éteindre l'écran : la vidéo s'arrête (*Paramètres › Batterie* : consommation d'« Eventide Démo » faible après une nuit) ; au retour elle reprend.
4. Changer de paysage depuis l'application et le remettre en fond d'écran : le nouveau paysage apparaît.
5. Désinstaller puis réinstaller, ou effacer les données : le fond d'écran n'empêche rien (Android revient au fond par défaut ou montre un fond sombre).
6. Version *release* (R8) : tout ce qui précède, et la carte de lecture (§ 15.6, point 9).

## 18. Orage et ambiance des paysages

Retour du product owner après la démo sur le Galaxy S24 : le son ne correspondait pas à l'image (la vidéo `pluie-ville` montrait des éclairs sur la ville, sans tonnerre, alors que la vidéo d'origine avait sa bande son). Le contrat d'API § 11 en fait des règles ; voici comment l'application les applique.

### 18.1 Ambiance d'un paysage

- Un son du catalogue avec le champ `paysage` (`CatalogItem.landscapeId`) est l'**ambiance** de ce paysage : sa bande son d'origine, sans tonnerre, en boucle sans raccord d'au moins 60 s (`tools/media/make_ambiance.py`). C'est une couche comme les autres (niveau, sourdine, minuteur, carte de lecture) ; le mix par défaut du paysage la met en tête.
- « Mon mix » ne la propose qu'avec son paysage (`CatalogItem.offeredWith`) ; une scène partagée qui la porte avec un autre paysage reste valide et la joue.
- `ambiance-cascade-foret` est gratuite et embarquée ; `ambiance-pluie-ville` est Premium (S3) ; `ambiance-toits-pluie` vient d'une vidéo de tiers : démo seulement. Un son ni embarqué ni listé dans `remote.json` (`ContentRepository.isPublished`) est laissé de côté sans message : en production, `toits-pluie` joue sans son ambiance.

### 18.2 Tonnerre : un son à événements

- `tonnerre` a `lecture: evenements` (`CatalogItem.events`, `EventSound`) : pas de boucle, mais une de ses dix variantes (`audio/sons/tonnerre-01.ogg`…) de temps en temps. Le contrôleur (`RealAppModel._prepare`) en fait une `EventLayer` (clé `son:tonnerre`, volume = niveau × gain de catégorie, 0 en sourdine) jointe à la `PlayRequest` ; chaque variante n'est trouvée (embarquée, en cache) ou téléchargée qu'au moment où un événement en a besoin, pendant l'éclair. Premium hors connexion : les variantes sont téléchargées avec les autres sons (`prefetchForOffline`).
- **Ordonnanceur** (`EventSoundScheduler`, `lib/services/audio/event_scheduler.dart`), porté par `PlaybackHandler`, donc par le service audio en arrière-plan : le tonnerre continue écran éteint. Règles (contrat § 11) :
  - premier événement `premier_s` (45 à 120 s) après le début de l'écoute, une reprise après pause, l'ajout du son ou son retour d'un niveau 0 ou de la sourdine ; ensuite un écart tiré dans `intervalle_s` (120 à 300 s) d'un événement au suivant ;
  - variante au hasard, jamais une des deux dernières ; volume −6 à 0 dB, vitesse 0,92 à 1,08, position stéréo −0,4 à 0,4 (`StormRules`, `lib/core/lightning.dart`) ;
  - jamais deux événements en même temps : un événement dû pendant qu'un autre sonne attend sa fin ;
  - rien pendant une pause (la pause arrête aussi le tonnerre qui sonne), pendant le fondu de fin du minuteur, ni une fois arrêté ; niveau 0 ou sourdine : plus d'événement, et celui qui sonne s'éteint en fondu (`setEventVolume`) ; un changement de niveau s'applique aussi à celui qui sonne ;
  - un fichier introuvable (hors connexion, absent) : cet événement est sauté, le suivant est prévu.
- **Moteur** : `AudioEngine.playEvent` (une voix non bouclée par-dessus les couches, avec son gain, sa vitesse `setRelativePlaySpeed` et sa position `pan`, qui suit le volume global : montée, atténuation, fondu de fin) et `setEventVolume`. Le fichier est lu depuis le disque et libéré à la fin de l'événement.
- **Le tonnerre seul** (toutes les autres couches retirées) : une voix silencieuse, garée (volume 0, jamais décodée), porte la séance (`carrier`), pour que pause, minuteur et carte de lecture fonctionnent comme avec n'importe quel mix.

### 18.3 Éclair synchronisé

- Avant chaque tonnerre, l'ordonnanceur annonce un `LightningStrike` (`AppModel.lightningStrikes`, flux du service audio) : l'éclair est dessiné tout de suite, le tonnerre suit 0,4 à 3,5 s plus tard ; plus le délai est court, plus l'éclair est vif (`intensity` 1 à 0,35).
- Le décor (`DecorLayer`, `lib/ui/landscape/decor_layer.dart`) ne le dessine que si « Éclairs lointains » est dans la scène et que le paysage est visible (Accueil au premier plan, aucun écran par-dessus) ; sinon le tonnerre gronde sans éclair.
- **Un éclair** : vif mais bref, un flash principal (montée en 30 ms) et un second plus faible à 0,3 s, fini en 0,6 s ; jamais de stroboscope (deux flashs au plus, bien sous le seuil de 3 par seconde). La lumière vient d'un point du ciel tiré au hasard ; pour un éclair proche, toute l'image s'éclaire un peu.
- **« Réduire les animations »** : une simple lueur douce du ciel (montée et descente en 1,6 s, intensité 0,35 au plus).
- **Sans tonnerre dans le mix** (aucun son à événements au-dessus de 0, `Catalog.hasEventSound`) : le décor fait ses propres éclairs, rares (un toutes les 2 à 5 minutes de paysage visible) et silencieux. Avec un tonnerre dans le mix, il n'en fait aucun de lui-même (même en pause : pas de tonnerre, pas d'éclair).

### 18.4 À vérifier sur le Galaxy S24

1. `pluie-ville` : ambiance de pluie dense, sans tonnerre dans la boucle ni raccord audible (67 s) ; la vidéo n'a plus d'éclair.
2. Premier tonnerre entre 20 s et 1 min après la lecture, puis toutes les 70 s à 3 min environ (resserré le 29 octobre 2026 à la demande du product owner), jamais deux fois le même de suite ; éclair juste avant, puis le grondement.
3. Écran éteint 20 min : les tonnerres continuent (service au premier plan) ; pause : plus rien ; reprise : un nouveau délai.
4. Sourdine des sons : plus de tonnerre ; « Réduire les animations » : lueur douce seulement.
5. Mix « tonnerre seul » : la séance tient (minuteur, carte de lecture).

## 19. Plantage au défilement des paysages dessinés et garde-fou

Retour du product owner (Galaxy S24 SM-S921B, Android 16, démo optimisée par R8, rendu Impeller) : en faisant défiler vers le bas le thème Nature (cascade-foret, sous-bois, berge-mousseuse, torrent-montagne, pierres-eau, **lisiere-verte**), l'application plante en arrivant au dernier paysage, à chaque essai, puis **à chaque démarrage** ; seule la réinstallation la débloque.

### 19.1 Cause

- Les paysages sans vidéo ni image fixe sont **dessinés** par `lib/ui/landscape/landscape_painter.dart`, puis rendus **hors écran sur le processeur graphique** (`toImageSync`, `LandscapeRasterCache`) : en plein écran (672 × 1456 px sur le S24), pour les **voisins** avant un balayage (`_prewarmNeighbors`), pour la **vignette** du menu, et en 720 × 720 pour la **carte de lecture**. Une erreur Dart n'arrête pas une application Flutter optimisée : un arrêt net est un **plantage natif** (pilote graphique Vulkan, Impeller), invisible du code Dart.
- La version 1 du dessin demandait au processeur graphique, par image, jusqu'à **5 000 flous** (`MaskFilter.blur`, chacun une passe hors écran ou un calcul de flou) et **262 découpes** (`clipPath`, des passes de pochoir). Mesuré ici (`test/ui/audit_canvas.dart`) : pierres-eau 5 718 dessins, 4 978 flous, 262 découpes ; aurore-boreale 730 flous de lignes en mode additif ; **lisiere-verte est le seul paysage qui découpe selon un contour fait de 26 disques superposés** (le feuillage de l'arbre) et y dessine 260 points flous, plus une copie floue de ce même contour. Sous-bois, berge, torrent et pierres ont été traversés sur le S24 sans plantage (product owner) ; café et aurore vraisemblablement aussi (voisins de paysages affichés dans le rapport de 10 minutes).
- **En défilant**, aucune image de la carte n'attendait le son : elle était dessinée pour **chaque** paysage traversé pendant une écoute (sous-bois, berge, torrent, pierres, lisière : 5 dessins 720 × 720 en plus des pleins écrans et des voisins), donc une charge cumulée sur le processeur graphique au moment d'arriver au dernier.
- **À chaque démarrage** : `scene.json` (paysage de la scène, mis à jour 1,5 s après l'arrivée) et `app_state.json` (`last_landscape_by_theme`, 0,4 s après) gardent lisiere-verte ; le démarrage la dessine alors à nouveau, comme paysage affiché, comme voisin de pierres-eau, ou comme voisin de droite d'un paysage Urbain.
- **Non prouvé sans le téléphone** : l'appel natif exact qui tue le processus. Ici, avec `flutter test --enable-impeller` (Impeller sur Vulkan logiciel SwiftShader, sous Linux), tous les paysages se rendent sans plantage et toutes les valeurs sont finies (géométrie, flous ≤ 26 px, textures ≤ 1 456 px) : le défaut vient du pilote du S24 (Exynos 2400, Xclipse 940) face à ce volume ou à cette forme de travail.

### 19.2 Correction (dessin version 2)

- **Aucune découpe** (`clipPath`) : les détails restent dans leur forme par un test de point fait en Dart au moment de l'enregistrement.
- **Aucun flou** sur les points, ovales, bandes et traits : dégradés radiaux ou linéaires « adoucis » (un seul dessin, aucune passe hors écran) ; les flous qui restent ne portent que sur quelques **grandes formes** (bois lointains, falaise, brume), regroupées, **6 au plus** par image (`kMaxBlurredShapesPerLandscape`). lisiere-verte : 0 flou, 0 découpe ; pierres-eau : 2 057 dessins, 0 flou, 0 découpe. Le rendu est quasi identique (comparé image par image).
- **Moins de travail à la fois** : voisins dessinés un par image affichée, jamais ensemble ; image de la carte seulement pour le paysage que le son suit, une à la fois (`MediaArtwork`), fichiers renommés `-v2`.
- Tests : `test/ui/landscape_budget_test.dart` (chaque style, aux tailles du S24 : écran, vignettes, carte ; aucune découpe, au plus 6 flous et seulement sur des formes, moins de 2 200 dessins, valeurs finies ; rendu réel de chaque style et de chaque moment), aussi lancé avec `--enable-impeller`.

### 19.3 Garde-fou contre les plantages en boucle

`lib/core/crash_guard.dart` (`CrashGuard`, logique pure) et `FileGuardStore` (`diagnostics/guard.json`, écrit de façon **synchrone** et atomique : rien ne s'exécute après un plantage natif).

- **Démarrage** : marqué juste avant le premier paysage dessiné (`LandscapeBackground`), effacé après **20 s** stables ou au passage normal en arrière-plan. Encore marqué au lancement suivant : **démarrage protégé** : retour sur **Cascade en forêt** (gratuit, vidéo et image fixe embarquées, jamais dessiné), paysages par thème oubliés, écrit tout de suite ; favoris, programmations, réglages, moment, minuteur et sourdines gardés.
- **Dessin** : chaque dessin hors écran (plein écran, vignette, image de la carte) est marqué avant (style, taille) et effacé après (image de la carte : quand le PNG est prêt ; `toImageSync` : après l'image affichée suivante plus 2 s, `LandscapeRasterCache.settleDelay`). Encore marqué au lancement suivant : ce style est montré **simplifié** (`SimplifiedLandscapePainter` : trois dégradés, dessinés directement, rien hors écran) jusqu'à la prochaine version de l'application ou du dessin.
- Le journal du rapport de problème (§ 16) nomme le dernier dessin commencé et, au lancement suivant, « démarrage protégé » ou « lancement précédent arrêté pendant : paysage lisiere 672×1456 ».
- Un démarrage programmé sans écran ne marque rien (aucun paysage dessiné). Un utilisateur qui ferme l'application dans les 2 s d'un dessin peut rendre un style simplifié à tort : sans gravité.

### 19.4 À vérifier sur le Galaxy S24

1. Installer la nouvelle démo (désinstaller l'ancienne d'abord si elle plante au démarrage).
2. Nature : du haut (Cascade en forêt) jusqu'en bas (**Lisière verte**), lentement puis vite, son en lecture puis en pause ; rester 10 s sur Lisière verte ; quitter et rouvrir l'application. Même chose pour Astral jusqu'à **Lune sur le lac**, et Urbain jusqu'à Toits sous la pluie.
3. Changer de thème depuis Lisière verte (vers Urbain) et revenir ; écran verrouillé, « suivant » / « précédent » de la carte sur les paysages dessinés : l'image de la carte arrive environ 1,5 s après le titre.
4. Les paysages dessinés ressemblent à avant (pierres, aurore, lisière).
5. En cas de nouvel arrêt : rouvrir l'application (elle doit repartir sur Cascade en forêt ou montrer le paysage en cause simplifié), puis Réglages › « Signaler un problème » : le rapport doit contenir la raison Android (plantage natif, ANR…) et la ligne « dessin : … » juste avant ; idéalement aussi `adb bugreport` (les *tombstones* complètes).

## 20. Paysages imaginaires (3D)

Décision du product owner (29 octobre 2026, [contrat § 12](../api/contrat-v1.md)) : le décor d'un paysage filmé ne se modifie plus ; les éléments du décor appartiennent à une quatrième catégorie, « Imaginaire », de six scènes 3D dessinées en direct par l'application avec three.js, où l'utilisateur ajoute ou retire des éléments. Exigence de direction artistique : calme, lent, belle lumière, profondeur, léger parallaxe, rien de criard ni de « dessin animé », texte blanc lisible dans le tiers inférieur.

### 20.1 Runtime (`app/assets/imaginaire/`, hors ligne)

| Fichier | Rôle |
|---|---|
| `index.html` | page vide (fond noir) qui charge les scripts ; politique de sécurité qui interdit tout accès réseau (`connect-src`, `img-src`, `media-src`… à `'none'`) |
| `vendor/three.min.js` | three.js 0.186.1 (npm, version épinglée), regroupé en **script classique** (global `THREE`) par `tools/imaginaire/build-three.mjs` ; licence MIT dans `vendor/LICENSE-three.txt` |
| `runtime.js` | API `window.eventide`, boucle de rendu, temps, transitions du décor, messages, miroir d'eau, mode enregistrement ; une scène à finition HDR (`post: true`) dessine elle-même ses images |
| `decors.js` | les dix éléments du décor, partagés par les scènes (§ 20.3) |
| `scenery.js` | lignes de sapins et profils de montagnes dessinés par des shaders |
| `post.js` | finition HDR partagée, pour les scènes qui la demandent (aujourd'hui la forêt, § 20.7) : cible HDR demi-flottante avec MSAA 4×, bloom à demi-résolution (5 niveaux), **une** passe de composition (exposition, courbe ACES, bloom, rayons de lumière, légère aberration chromatique, vignette, grain de film, tramage) |
| `scenes/<id>.js` | une scène ; chargée à la demande par `start()` |

**Pourquoi des scripts classiques** : three.js n'est plus publié qu'en modules ES, et la WebView Android refuse les imports de modules depuis `file:///android_asset/` (origine opaque, CORS) tant que « file access from file URLs » est désactivé, ce que `webview_flutter` n'expose pas. Avec des scripts classiques, `loadFlutterAsset('assets/imaginaire/index.html')` suffit, sans réglage.

**API** (`window.eventide`) :

| Appel | Effet |
|---|---|
| `start(id, {decor: {id: 0..100}, moment, quality: 'low'\|'high', fps: 30})` | construit la scène (promesse résolue à la première image) ; décors inconnus ou non permis ignorés |
| `setDecor(id, niveau)` | 0 à 100, transition adoucie d'1 s ; 0 retire l'élément (plus aucun dessin) |
| `setMoment(m)` | accepté ; les six scènes ont leur propre lumière et l'ignorent |
| `setPaused(bool)` | `true` arrête la boucle de rendu (plus aucune image, aucun calcul) |
| `setQuality(q)` | `low` : rapport de pixels 1 et 60 % des particules ; `high` : rapport de pixels ≤ 1,5 et toutes les particules. `low` allège aussi la forêt (sans MSAA, bloom, rayons, aberration ni grain : courbe de tons seule ; brume plus légère et immobile ; ombre de lune en 512²) et, au démarrage, la mer de nuages (800 nuages au lieu de 1 300) ; l'anticrénelage (MSAA) n'existe qu'en `high` |
| `dispose()` | libère tout (géométries, matériaux, contexte WebGL) |

Messages vers l'application par le canal JavaScript `EventideScene` (JSON) : `{"type":"ready"}` après la première image, `{"type":"error","detail":"…"}` (erreur JavaScript, scène inconnue, `webglcontextlost`), `{"type":"stats","fps":n,"ms":n}` toutes les 10 s (`ms` : temps JavaScript moyen d'une image). Sans canal (navigateur de bureau), les messages vont dans la console. Un contexte WebGL perdu puis rendu reconstruit la scène.

**Temps** : la boucle avance d'au plus 0,1 s par image (pas de saut après une pause du système) et dessine au plus `fps` images par seconde (30 par défaut, plafond). L'image est une **fonction pure du temps modulo 30 s** : tout ce qui bouge tourne un nombre entier de fois par période (sinusoïdes à fréquences entières, particules qui retombent un nombre entier de fois, bruits qui défilent par fondu enchaîné de deux copies décalées d'une demi-période, chacune revenant en arrière quand son poids et la pente de ce poids sont nuls : la valeur et sa vitesse restent continues, au raccord compris). Les détails plus fins qu'un pixel (rides lointaines de l'eau) sont estompés selon leur taille à l'écran, pour ne pas scintiller. La période de 30 s se répète donc sans raccord, et l'image de fond d'écran en est tirée.

**Mode enregistrement** (outils seulement) : `index.html?record=1&scene=<id>&t=<s>&w=<px>&h=<px>&decor=<json>` dessine exactement une image au temps `t` (rapport de pixels 1, anticrénelage 4×) puis met `window.eventideFrameReady = true` ; `window.eventideRenderAt(t, décor)` dessine les suivantes. `describe()`, `info()` (compteurs de la dernière image) et `debug()` servent aux outils.

### 20.2 Les six scènes

| id | Scène | Décors permis (défaut) |
|---|---|---|
| `foret-lucioles` (gratuite) | Sentier dans une forêt d'épicéas, la nuit : lune basse dans la brume, rayons entre les branches, fougères, rochers moussus, tronc couché, lucioles ; vraie forêt 3D et finition HDR (§ 20.7) | lucioles 60, brume 30, feuilles, pluie, étoiles |
| `lac-lune` | Lac de montagne la nuit : grande lune voilée de nuages fins, chaînes de montagnes bleues, rive de sapins, reflet réel dans l'eau ridée, chemin de reflets de lune, roseaux | étoiles 60, brume 30, étoiles filantes, lucioles, neige |
| `aurore` | Nuit arctique : trois voiles d'aurore qui se plient lentement derrière des montagnes enneigées, reflétés par un lac immobile, sapins enneigés | étoiles 50, neige 30, étoiles filantes, brume |
| `jardin-zen` | Jardin sec au petit matin : gravier ratissé en cercles autour de pierres moussues, haie taillée, bambous dans la brume dorée, branche de cerisier en fleur, bassin sombre au premier plan | pétales 40, rayons de soleil 30, brume, pluie |
| `mer-nuages` | Au-dessus d'une mer de nuages à l'aube : 1 300 nuages éclairés à contre-jour qui dérivent vers le spectateur, sommets violets, crête sombre au premier plan | oiseaux en vol 30, rayons de soleil 40, étoiles, étoiles filantes, brume |
| `ondes` | Abstraite et hypnotique : un champ de 31 500 points de lumière traversé de vagues concentriques lentes ; une onde part du centre trois fois par période ; sous la pluie, chaque goutte ouvre un anneau | étoiles 40, brume, pluie |

Le tiers inférieur reste sombre et calme dans les six scènes (sol, eau sombre près du spectateur, crête), pour le texte blanc de l'application.

### 20.3 Éléments du décor (`decors.js`)

Chaque élément est **un seul appel de dessin** (les rayons de soleil : deux, avec leurs poussières), animé entièrement dans le shader de sommets. Chaque particule a un rang dans [0, 1] et n'apparaît que si le niveau dépasse son rang, avec un fondu : le niveau règle la densité, et un peu l'intensité. Les paramètres (volume, couleurs, lumière) viennent de la scène. La forêt (§ 20.7) a ses propres versions HDR de `lucioles`, `brume`, `feuilles` et `pluie`, dans `scenes/foret-lucioles.js` ; ses `etoiles` viennent de `decors.js`.

| Élément | Rendu |
|---|---|
| `lucioles` | jusqu'à 210 points chauds qui dérivent et s'allument par pulsations lentes |
| `brume` | bancs de brume (voiles de bruit qui dérivent) et brouillard de toute la scène plus épais |
| `feuilles`, `petales` | petites formes à deux faces qui tombent en tournoyant (les pétales dérivent aussi avec le vent), éclairées par la lumière de la scène, translucides à contre-jour |
| `pluie` | traits fins orientés selon la chute (largeur en pixels), jusqu'à 1 100 gouttes ; grise un peu la lumière du jardin, ride le bassin, ouvre des anneaux sur les ondes |
| `neige` | flocons en points, flous quand ils sont proches (profondeur de champ) |
| `etoiles` | jusqu'à 1 500 étoiles sur la voûte, scintillement lent, bande de la Voie lactée dans les scènes de nuit |
| `etoiles-filantes` | six passages par période au plus, à des instants fixes |
| `oiseaux-vol` | silhouettes lointaines (ailes articulées, battements et planés) : vols en V qui traversent et oiseaux qui tournent dans les ascendances |
| `rayons-soleil` | faisceaux de lumière en éventail qui respirent, avec des poussières qui scintillent dedans |

### 20.4 Budget et mesures

Budget (téléphone) : ≤ 30 i/s, rapport de pixels ≤ 1,5, moins de 150 appels de dessin, géométrie et textures procédurales (aucune image chargée). Aucun post-traitement, sauf la finition HDR de la forêt (§ 20.7 : une cible HDR, un bloom à demi-résolution, une passe de composition) ; ailleurs, le seul rendu supplémentaire est le reflet de l'eau, dans une texture à 35-40 % de la taille de l'écran.

Mesures (`node tools/imaginaire/render.js stats`, Chromium sans écran, WebGL logiciel SwiftShader sur 4 cœurs, faute de GPU) :

| Scène | Appels de dessin (sans décor / défaut / tout à 100) | Triangles (défaut / tout à 100) | Points (défaut) | Programmes (défaut) | Temps logiciel par image, 540 × 1170 |
|---|---|---|---|---|---|
| `foret-lucioles` (v2, § 20.7) | 41 / 42 / 45 | 480 102 / 483 142 | 248 | 21 | 1 891 ms (`low` : 966 ms) |
| `lac-lune` | 15 / 23 / 28 | 5 474 / 5 498 | 3 254 | 7 | 146 ms |
| `aurore` | 19 / 22 / 30 | 8 658 / 8 694 | 5 272 | 8 | 166 ms |
| `jardin-zen` | 33 / 37 / 44 | 41 272 / 43 484 | 990 | 12 | 149 ms |
| `mer-nuages` | 7 / 10 / 15 | 3 757 / 3 775 | 0 | 8 | 392 ms |
| `ondes` | 2 / 3 / 6 | 960 / 2 764 | 32 876 | 3 | 32 ms |

Les appels de dessin comptent le reflet de l'eau (`lac-lune`, `aurore`, `jardin-zen` dessinent la scène deux fois) et, pour la forêt, la carte d'ombre de la lune et les 10 passes de la finition HDR. Toutes les scènes restent sous 50 appels, loin du budget de 150 ; les autres scènes sous 45 000 triangles, la forêt v2 à 480 000 (dont 156 000 pour la carte d'ombre).

Le temps logiciel n'est qu'un **indicateur relatif** du coût GPU (un GPU de téléphone est de l'ordre de 50 à 100 fois plus rapide que SwiftShader sur 4 cœurs). La forêt v2 (vraie géométrie, matériaux physiques, finition HDR) est de loin la plus coûteuse, puis la mer de nuages (recouvrement de 1 300 nuages) ; `quality: 'low'` les allège.

### 20.5 Image fixe et boucle de fond d'écran

Tirées de la scène elle-même par `tools/imaginaire/render.js` (voir [`tools/imaginaire/README.md`](../../tools/imaginaire/README.md)) : 720 images (24 i/s, une période de 30 s) rendues en 720 × 1280, agrandies en 1080 × 1920, encodées en H.264 sans son ; image fixe = première image décodée de la vidéo (JPEG ≤ 300 Ko).

- Images fixes des six scènes : **embarquées** (`app/assets/landscapes/<id>.jpg`), pour que les vignettes Premium s'affichent aussi aux utilisateurs gratuits.
- Boucle de la scène gratuite embarquée (`app/assets/landscapes/foret-lucioles.mp4`) ; boucles Premium sur S3 (`content/videos/paysages/<id>.mp4`), listées dans `remote.json`, copiées dans la démo par `tool/ci/bundle_demo_media.sh`.
- `tool/ci/check_apk_contents.sh` exige dans tout APK le runtime, les six scènes, les six images fixes et la boucle de la forêt.

Mesures (`node tools/imaginaire/render.js seam`, H.264 High, yuv420p, 1080 × 1920, 24 i/s, 30,0 s, sans son) :

| Scène | Boucle | Taille | CRF | Image fixe | Raccord du master (dernière → première / pas médian) | Raccord publié / pas médian aux images clés |
|---|---|---|---|---|---|---|
| `foret-lucioles` (v2) | embarquée | 3,43 Mo | 36 | 172 Ko | 1,16 | 1,16 |
| `lac-lune` | S3 | 2,23 Mo | 31 | 99 Ko | 0,96 | 1,03 |
| `aurore` | S3 | 2,83 Mo | 31 | 86 Ko | 1,19 | 1,12 |
| `jardin-zen` | S3 | 2,49 Mo | 30 | 117 Ko | 1,18 | 1,11 |
| `mer-nuages` | S3 | 2,20 Mo | 28 | 71 Ko | 1,08 | 1,14 |
| `ondes` | S3 | 3,77 Mo | 32 | 83 Ko | 1,11 | 1,07 |

- **Raccord** : écart moyen (gris, 270 × 480) entre la dernière et la première image, rapporté à l'écart médian entre deux images consécutives ; 1 signifie que le passage de 30 s à 0 s ressemble à n'importe quel autre pas. Dans le master sans perte, le raccord est partout inférieur au plus grand pas ordinaire de la boucle. Dans la vidéo publiée, la première image est une image clé : le raccord se compare donc aux autres passages sur une image clé (toutes les 2 s), qui portent le même petit saut d'encodage.
- **Taille** : l'encodeur prend le plus petit CRF (au plus 30) qui tient dans 2,5 Mo (contrat § 8) ; sinon le plus petit qui tient dans 4 Mo. `aurore` (voiles fins qui bougent sur tout le ciel) et `ondes` (32 000 points en mouvement) dépassent 2,5 Mo sans dépasser 4 Mo : à 2,5 Mo (CRF 33 et 36), les voiles se lissent en aplats et les points lointains s'effacent. C'est un écart au contrat § 8, à trancher par le product owner : l'accepter (et l'écrire au contrat) ou réencoder avec `render.js video --reuse-master --strict --scene aurore,ondes`.
- **Forêt v2** : la vraie géométrie (aiguilles, fougères) bouge avec la caméra à chaque image ; même sans grain, la boucle ne tient dans 4 Mo qu'au CRF 36 (3,43 Mo), et dans 2,5 Mo vers le CRF 39 (images nettement dégradées). Un léger flou avant l'encodage, ou deux fois moins de mouvement de caméra, n'y changent presque rien (−17 % au mieux). C'est le même écart au contrat § 8 que `aurore` et `ondes`, sur un fichier **embarqué** (+1,1 Mo dans l'APK par rapport à la v1). Les images clés (toutes les 2 s) rafraîchissent ce que les images P ont perdu : leur saut moyen vaut 3,5 fois un pas ordinaire (comme les autres boucles, mais plus fort au CRF 36).
- **Image fixe** : la première image décodée de la vidéo, en JPEG (écart moyen à cette image : 0,17 à 0,31 sur 255).

### 20.6 À vérifier sur le Galaxy S24

1. Chaque scène s'affiche en moins d'une seconde, sans image noire (l'app garde l'image fixe jusqu'au message `ready`).
2. 30 i/s stables dans les six scènes, décor par défaut puis tous les éléments à 100 ; message `stats` toutes les 10 s.
3. Téléphone tiède mais pas chaud après 30 min sur la forêt et la mer de nuages (les deux plus coûteuses) ; sinon `quality: 'low'`.
4. Transitions d'un élément de 0 à 100 et retour : douces, environ 1 s.
5. Pause : plus aucune consommation GPU (la boucle s'arrête).
6. Fond d'écran animé : la boucle repart sans saut visible.
7. Forêt (finition HDR, § 20.7) : pas de message `error` au démarrage (cible demi-flottante et MSAA acceptés par le pilote), 30 i/s en `high` après 2 min, téléphone tiède après 30 min ; sinon `low`, et le noter ici.

### 20.7 Forêt aux lucioles, version 2 (rendu HDR)

Demande du product owner (29-30 octobre 2026) : « je ne demande pas que tu reproduises ce qui est écrit dans le prompt, mais je veux un rendu de la même qualité pour ce que nous sommes en train de faire ». Le niveau de finition d'une démo three.js de « motion design » (matériaux physiques, HDR, bloom discret, courbe de tons, grain, profondeur, contrôle image par image) appliqué à une forêt calme de nuit, pour dormir, « vraiment naturelle » ; rien du contenu de la démo (ni interface, ni panneaux de verre, ni couleurs).

**Scène** (`scenes/foret-lucioles.js`, tout procédural : aucune image chargée) :

- **Épicéas** : trois formes, chacune en trois niveaux de détail instanciés (258 arbres : 39 proches, 65 moyens, 154 lointains). Tronc conique avec contreforts, écorce procédurale (plaques et fissures, lichen, mousse au pied, relief par dérivées d'écran). Houppiers de branches tombantes : cartes pliées en toit, portant une texture de rameau d'épicéa dessinée une fois en JavaScript (pousses en goupillon couvertes d'aiguilles), dont les mipmaps conservent la couverture ; alpha-to-coverage avec le MSAA. Près de la caméra, une branche est une suite de rameaux. Les houppiers voisins du sentier sont plus étroits près de la caméra ; plus loin, ils surplombent le sentier et découpent la lumière.
- **Sol** : litière (amas d'aiguilles, grain fin, feuilles mortes pâles), mousse, sentier tassé ; occlusion au pied des troncs et couvert des houppiers lus dans une petite carte calculée au démarrage. Fougères (frondes en arc, pinnules lobées), rochers à lichens et dessus moussu, coussins de mousse (matériau physique avec « sheen »), tronc couché, brindilles, cônes.
- **Lumière** : lune basse dans l'axe du sentier (lumière directionnelle, ombre 1024², PCF) et lumière d'ambiance du ciel ; image d'environnement (PMREM) seulement sur le sol, la pierre, le tronc couché, la mousse et les feuilles (les surfaces qui la montrent, mouillées surtout) ; translucidité à contre-jour des aiguilles, fougères et feuilles ; reflets spéculaires atténués sur les surfaces sèches et organiques, qui sinon brillent comme un bitume.
- **Air** : brouillard exponentiel en hauteur, avec un lobe de diffusion vers l'avant (Henyey-Greenstein) éclairé par la lune, et une **nappe de brume au sol intégrée analytiquement dans chaque shader** (aucune tranche, donc aucune ligne là où la brume touche un tronc) ; vers le bas, la nappe dérive (bruit qui boucle) et s'éclaire là où la carte d'ombre de la lune laisse passer la lumière. Le ciel reçoit le même air (aucune ligne d'horizon). Quelques poussières près de la caméra, visibles seulement dans la lumière.
- **Caméra** : petite orbite fermée (± 0,42 m de côté, 1,1 m d'avance) par période de 30 s : parallaxe réelle entre troncs proches, rangées lointaines et brume.

**Finition** (`post.js`, réutilisable par les autres scènes) : rendu dans une cible HDR demi-flottante avec MSAA 4× ; bloom à demi-résolution (5 niveaux, filtre « dual », moyenne de Karis contre le scintillement) ; **une seule** passe de composition : exposition, courbe ACES, bloom, rayons de lune (12 pas vers la lune sur le niveau ¼ du bloom, autour de la lune seulement : les trouées entre les branches font les rayons), aberration chromatique légère vers les bords, vignette, grain de film (un motif par 1/24 s du temps de la scène : l'image reste une fonction du temps, la boucle reste exacte), tramage. Le grain n'existe qu'en direct : dans la boucle de fond d'écran, un motif neuf à chaque image est ce que H.264 garde le plus mal (essai : 3,7 Mo au CRF 35). Sans demi-flottant rendu par le pilote, la cible passe en 8 bits.

**Décor** : `lucioles` (points émissifs HDR que le bloom auréole, clignotements, trajectoires lentes, atténués par la brume), `brume` (air plus épais, nappe au sol plus dense), `feuilles` (matériau physique, ombres de la lune, translucides à contre-jour), `pluie` (traits éclairés par la lune là où elle passe, d'après la carte d'ombre ; sol, écorce et aiguilles mouillés, flaques sur le sentier qui reflètent la lueur, anneaux de gouttes), `etoiles` (`decors.js`, plus brillantes).

**`quality: 'low'`** : sans MSAA (test alpha), sans bloom, rayons, aberration ni grain (courbe de tons seule), brume plus légère et sans dérive ni lumière propre, ombre en 512² ; au démarrage en `low`, aussi 140 lucioles, 110 fougères et 800 gouttes.

**Mesures, v1 → v2** (Chromium sans écran, WebGL logiciel SwiftShader ; tampon du Galaxy S24 : écran 1080 × 2340, rapport de pixels plafonné à 1,5, donc 540 × 1170 px) :

| | v1 (rangées de sapins par shader) | v2 `high` | v2 `low` |
|---|---|---|---|
| Appels de dessin (sans décor / défaut / tout à 100) | 10 / 14 / 17 | 41 / 42 / 45 (dont 10 pour la carte d'ombre, 10 pour la finition) | 32 / 33 / 36 (1 passe de finition) |
| Triangles (défaut) | 14 180 | 480 102 (324 000 à l'écran, 156 000 dans la carte d'ombre) | 480 093 |
| Arbres | 7 rangées dessinées par pixel | 258 épicéas : 39 proches, 65 moyens, 154 lointains | idem |
| Cibles de rendu (540 × 1170) | aucune (MSAA 4× du canevas) | HDR demi-flottante MSAA 4× : 35,4 Mo ; bloom : 3,4 Mo ; ombre 1024² : 4,2 Mo ; environnement : 0,2 Mo ; **≈ 43 Mo** (le canevas perd son MSAA et sa profondeur) | HDR sans MSAA : 7,6 Mo ; ombre 512² : 1 Mo ; **≈ 9 Mo** |
| Fragments des matériaux éclairés | — | 1,33 par pixel avec test de profondeur précoce idéal, 3,63 au pire (84 % de l'écran couvert, le reste est le ciel), soit 0,84 à 2,3 millions d'appels du shader par image | idem, shader allégé |
| Finition | — | bloom ≈ 0,42 million de fragments (3,3 millions de lectures de texture) ; composition 0,63 million × 16 lectures (12 pour les rayons) | composition seule (1 lecture) |
| Temps logiciel par image, 540 × 1170 | 344 ms | 1 891 ms (× 5,5) | 966 ms (× 2,8) |

L'essentiel du coût vient des houppiers (cartes d'aiguilles superposées, ombrées en matériau physique) ; `high` coûte deux fois `low` (MSAA, finition, brume qui dérive et s'éclaire, ombre 1024²). Déjà retiré en cours de travail : l'image d'environnement sur les aiguilles, fougères et troncs (−36 %), la brume dérivante et l'ombre dans la brume pour les rayons qui montent (−28 %). Le coût réel sur le S24 (GPU Xclipse 940) n'est pas mesuré ici : c'est l'élément 7 du § 20.6 qui tranche ; sinon `low`, ou moins d'arbres proches.
