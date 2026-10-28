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
| `android/app/src/main/kotlin/` | Alarmes exactes, récepteurs, notifications de secours, Play Integrity, canal `be.cinaf.eventide/native` | — |

Services : `storage.dart` (fichiers JSON), `api_client.dart` (API, jeton d'installation), `connectivity.dart`, `content_repository.dart` (sons embarqués, cache, téléchargements), `audio/` (moteur, focus, service de lecture), `voice/` (reconnaissance, chaîne vocale), `billing_service.dart`, `ads_service.dart`, `account_service.dart`, `links_service.dart` (feuille de partage, App Links, pages externes par `url_launcher`), `permissions_service.dart`, `native_bridge.dart`.

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
- **Pas de sortie audio** (émulateur sans son, pilote audio en panne) : l'ouverture du périphérique échoue ou ne répond pas en 15 s, le démarrage échoue proprement, le lecteur revient à l'arrêt et l'application affiche « Le son ne peut pas démarrer pour le moment » ; l'interface reste utilisable.
- **Service au premier plan** : `PlaybackHandler` (`audio_service`, type `mediaPlayback`) porte le moteur, la notification de lecture (titre = paysage, sous-titre = texte du rappel d'une programmation, boutons lecture/pause et arrêt) et **le minuteur**, qui continue donc quand l'application est fermée. Fin du minuteur : fondu de 30 s, arrêt complet, l'écran n'est pas rallumé. « Toute la nuit » s'arrête après `limites.nuit_max_heures` (10 h). Le décompte est gelé pendant une pause.
- **Focus audio** (`audio_session`) : appel ou autre lecteur → pause, reprise automatique si l'interruption était passagère ; GPS ou notification → volume baissé ; casque débranché → pause. Balayer l'application hors des récentes laisse le son et son minuteur continuer.
- Le gratuit exige une connexion : avant de **démarrer** un son, un utilisateur gratuit fait une vraie vérification réseau (au plus une toutes les 2 minutes). Une écoute déjà en cours n'est jamais coupée ; seul le chargement d'un nouveau paysage ou d'un nouveau son est refusé hors connexion.
- **Contenus** (`ContentRepository`) : fichier embarqué `assets/audio/<sons|musiques>/<id>.ogg` s'il existe (éléments gratuits), sinon fichier déjà téléchargé, sinon téléchargement (adresse CloudFront signée par `POST /content/urls`, ou serveur local en debug). Pour Premium, tous les sons et musiques sont téléchargés en arrière-plan, un par un, en Wi-Fi seulement si le réglage est activé.

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
| `build` | `flutter analyze`, `flutter test`, `flutter build apk --debug` : le Kotlin et Gradle compilent (impossible sans accès à Google Maven) | `eventide-debug-apk` |
| `release-apks` | Versions *release* (R8) de production puis de démo, arm64-v8a et x86_64, signées avec la clé de debug ; l'APK de production n'a **aucun** son Premium (`assets/flutter_assets/assets/audio/sons/vagues.ogg` absent), paquet `be.cinaf.eventide`, nom « Eventide » ; l'APK de démo a tous les sons et musiques de `content/audio`, paquet `be.cinaf.eventide.demo`, nom « Eventide Démo » (`app/tool/ci/check_apk_contents.sh`) | `eventide-demo-galaxy-s24-arm64` (à installer sur le téléphone), `eventide-demo-emulator-x86_64`, `eventide-production-release-apks-debug-signed` |
| `page-alignment` | Pages de 16 Ko (Android 15+ et Google Play pour une cible ≥ 35) : chaque `lib/arm64-v8a/*.so` et `lib/x86_64/*.so` a des segments `LOAD` alignés sur au moins `0x4000`, et `zipalign -c -P 16 -v 4` passe (`app/tool/ci/check_16kb_alignment.sh`, qui nomme la bibliothèque fautive) | — |
| `emulator` (API 34 et 36) | Sur de vrais systèmes Android (émulateurs x86_64, écran 1080 × 2400) : A. l'APK *release* de démo s'installe, démarre (`am start -W`), reste en vie, passe en mode démo, sans `FATAL EXCEPTION`, ANR ni erreur Dart ; B. le test d'intégration (`integration_test/demo_flow_test.dart`, `flutter drive`) : Bienvenue, lecture et pause, un son Premium, un paysage Premium, une programmation, « Version démo » dans Réglages ; C. **non bloquant** : la programmation laissée par B se déclenche application en arrière-plan, et le chemin suivi (service de lecture ou notification « Lancer ») est noté (`app/tool/ci/emulator_checks.sh`) | `emulator-api-34`, `emulator-api-36` : captures d'écran, logcat, `dumpsys`, `scheduled-start.txt` |

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

## 12. Version démo

Une version pour montrer et tester l'application sur un téléphone **sans Google Play ni serveur**, avec Premium déjà actif. Elle ne peut pas être confondue avec la production ni publiée à sa place :

- **Deux verrous.** La propriété Gradle `eventide.demo=true` donne un autre paquet (`be.cinaf.eventide.demo`, suffixe `.demo`), le nom « Eventide Démo » sous l'icône et un drapeau dans le manifeste (`be.cinaf.eventide.DEMO_BUILD`, lu par `NativeBridge.isDemoBuild()`). Le Dart n'active le mode démo que si ce drapeau **et** `--dart-define=DEMO_MODE=true` sont présents (`DemoMode.resolve`) : un paquet de production compilé par erreur avec la *dart-define* reste normal, et l'APK de démo, signé par la clé de debug et d'un autre paquet, serait refusé par Google Play.
- **Construction** (comme la CI) :

  ```bash
  cd app
  cp ../content/audio/sons/*.ogg assets/audio/sons/          # sons et musiques Premium : démo seulement
  cp ../content/audio/musiques/*.ogg assets/audio/musiques/
  flutter build apk --release --split-per-abi --target-platform android-arm64 \
    --dart-define=DEMO_MODE=true --android-project-arg=eventide.demo=true
  git checkout -- assets/audio && git clean -f assets/audio   # ne jamais committer ces copies
  ```

- **Ce qui change** : droits forcés à la formule annuelle (Premium, assistant inclus), quel que soit le cache ; aucun appel au serveur pour les droits ; aucune publicité (`NoAdsService`) ; aucun appel à Google Play (`DemoBilling`) : l'écran Premium dit « Version démo : Premium est déjà actif », ses boutons sont désactivés, « Restaurer mes achats » répond par un message, « Gérer mon abonnement » n'existe pas ; écoute hors connexion et programmations sans limite ; voix par les règles du téléphone (sans `API_BASE_URL`, jamais de message de quota) ; mention discrète « Version démo » en bas de Réglages.
- **Sons Premium embarqués** : la CI copie `content/audio/sons/*.ogg` et `content/audio/musiques/*.ogg` dans `app/assets/audio/` **avant** la construction de la démo seulement ; `ContentRepository` préfère les fichiers embarqués. La CI vérifie que l'APK de production n'en contient aucun.

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
