# Médias provisoires (placeholders)

Ce dossier génère **tous les médias provisoires** d'Eventide à partir de rien :
boucles audio (sons de nature et musiques), icône de l'application, icônes de
lancement Android et logotype. Aucun enregistrement, aucun échantillon, aucune
photo : tout est synthétisé (numpy) ou dessiné (SVG). Ces fichiers sont libres
de droits tiers et **destinés à être remplacés** par les contenus sous licence.
Ils servent à tester le moteur audio (boucles, superposition, fondus) et
l'intégration.

## Prérequis

- Python 3 + numpy 2.x, `ffmpeg` compilé avec `libopus`.
- Node.js + Playwright avec Chromium (`require('playwright')`).

## Régénérer

Depuis la racine du dépôt :

```sh
python3 tools/media/generate_audio.py   # 18 boucles + silence.ogg (~1 min 30 sur 4 cœurs)
node tools/media/generate_icons.js      # logo, icônes Android, logotype
```

Options de `generate_audio.py` :

| Option | Effet |
|---|---|
| `--only vent harpe` | ne régénère que ces identifiants |
| `--check-only` | décode les `.ogg` existants et refait les mesures (jointure, loudness) |
| `--wav-dir DIR` | écrit aussi les masters WAV flottants (hors dépôt) |
| `--report fichier.json` | enregistre les mesures en JSON |
| `--plain-opus` | encodage ffmpeg brut, sans le traitement de jointure (comparaison uniquement) |

La génération est déterministe : chaque élément a sa graine (`crc32(id)`). Avec
les mêmes versions de numpy, ffmpeg et libopus, une nouvelle exécution produit
des fichiers identiques à l'octet près.

## Fichiers produits

| Chemin | Contenu |
|---|---|
| `app/assets/audio/sons/<id>.ogg`, `app/assets/audio/musiques/<id>.ogg` | éléments gratuits (`"gratuit": true` dans `catalog.json`), embarqués dans l'app |
| `content/audio/sons/<id>.ogg`, `content/audio/musiques/<id>.ogg` | éléments Premium, à téléverser sur S3 (voir `content/README.md`) |
| `app/assets/audio/silence.ogg` | 1 s de silence (préchauffage du moteur) |
| `app/assets/brand/logo.svg` | icône maîtresse (carré arrondi, comme la maquette) |
| `app/assets/brand/logo_1024.png`, `logo_512.png` | icône pleine page, opaque, sans coins arrondis (Play Store : Google applique son propre masque) |
| `app/assets/brand/wordmark.svg`, `wordmark.png` | logotype « Eventide », goutte en guise de point du i |
| `app/android/app/src/main/res/mipmap-*/ic_launcher.png` | icônes classiques 48/72/96/144/192 px |
| `app/android/app/src/main/res/mipmap-*/ic_launcher_{background,foreground,monochrome}.png` | calques de l'icône adaptative, 108 dp (108/162/216/324/432 px) |
| `app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` | icône adaptative (Android 8+) et calque monochrome pour les icônes à thème (Android 13+) |

Le catalogue fait foi : si un élément passe de gratuit à Premium (ou l'inverse),
le script l'écrit au bon endroit et supprime l'ancienne copie.

## Boucles audio

Caractéristiques : 48 kHz, stéréo (canaux légèrement décorrélés), Ogg Opus
64 kbit/s (`libopus`, `-application audio`, trames de 20 ms), environ −23 LUFS,
crête vraie ≤ −1 dBTP. Durées toutes différentes (23 à 47 s) pour que les
couches superposées ne se calent jamais entre elles : les sons de nature durent
pour la plupart un nombre premier de secondes, les musiques un nombre entier de
mesures.

| id | durée | contenu synthétique |
|---|---|---|
| eau-vive | 31 s | bruit rose modulé (remous), embruns, ~800 bulles |
| oiseaux | 41 s | cinq « espèces » (balayages FM, trilles, sifflets), fond de feuillage |
| vent | 37 s | bruit brun à rafales lentes, sifflements à bande étroite, feuilles |
| tonnerre | 47 s | quatre roulements (dont un qui chevauche la jointure), pluie lointaine |
| pluie-douce | 29 s | souffle de pluie, milliers d'impacts filtrés, quelques « plic » |
| ruisseau | 34 s | bulles groupées (babillage), gargouillis grave |
| vagues | 43 s | cinq vagues par boucle (houle, déferlement, écume, galets) |
| feu-de-camp | 26 s | grondement, flamme, crépitements en grappes, éclats, sifflement de sève |
| grillons | 23 s | quatre grillons (porteuse 3,9–4,8 kHz, impulsions), chœur lointain |
| chouette | 39 s | hululements (dont un lointain filtré), nuit venteuse |
| piano-doux | 35,2 s | piano feutré (partiels inharmoniques amortis), fa majeur, 8 mesures |
| harpe | 40,32 s | arpèges pincés, ré majeur, 16 mesures en 6/8 |
| flute | 36,8 s | flûte (sinus + souffle + vibrato) sur nappe douce, mi mineur |
| guitare-douce | 28,8 s | guitare Karplus-Strong en arpèges, sol majeur |
| cordes-lentes | 44,8 s | ensemble de cordes lent (dents de scie désaccordées), ré mineur |
| boite-a-musique | 26,4 s | lames de boîte à musique, berceuse en 3/4 |
| bols-tibetains | 45,5 s | bols frappés (partiels inharmoniques en doublets) et bourdon frotté |
| nappes-apaisantes | 42,5 s | nappes chaudes à filtre lent, la majeur |

### Périodicité par construction

Chaque élément est calculé sur un axe de temps **circulaire** de N échantillons :
- les fonds de bruit sont fabriqués dans le domaine fréquentiel (spectre
  gaussien complexe mis en forme, puis FFT inverse). Ils sont périodiques par
  construction ;
- filtres et réverbérations sont des convolutions circulaires (régime permanent
  de la boucle) : la queue de réverbération de la fin retombe au début ;
- les événements (chants, notes, crépitements…) sont ajoutés modulo N : un
  événement qui dépasse la fin se poursuit au début ;
- les oscillateurs continus et les LFO font un nombre entier de cycles par boucle.

### Opus et jointure

L'encodage ffmpeg brut ne boucle pas proprement, pour deux raisons :

1. L'encodeur démarre sur du silence et termine sur du bourrage. Les deux bords
   sont alors codés comme des transitoires, d'où un petit « tic » aigu à la
   jointure.
2. Le fichier contient ~13,5 ms de bourrage final, que seul le granule de fin
   permet de couper. Le lecteur en flux de flutter_soloud (`WavStream`) ne tient
   pas compte de ce granule et jouerait ce bourrage à chaque tour.

De plus, l'erreur de codage n'est pas périodique : un décodeur « à froid » au
début et « chaud » à la fin laissent une petite marche à la jointure.

Le script corrige ces trois points :
1. il encode l'extension circulaire [fin de boucle | boucle | début de boucle] ;
2. il garde les paquets qui couvrent exactement la boucle ;
3. il les fait précéder de **copies des 16 derniers paquets de la boucle** et
   règle le *pre-skip* OpusHead sur leur durée (15 360 échantillons, 320 ms).
   Le décodeur jette ces copies, mais il aborde l'échantillon 0 dans l'état où
   il quitte l'échantillon N−1 ;
4. il réécrit les pages Ogg (CRC compris) avec un granule final égal au total
   des paquets : **aucune coupe de fin n'est nécessaire**.

Résultat : avec libopus comme avec le décodeur natif de ffmpeg, chaque fichier
se décode en exactement N échantillons. Le code de flutter_soloud 5.2.2
(`mb_ogg.cpp`) applique le pre-skip même sur plusieurs paquets, en mode mémoire
(`Wav`) comme en flux (`WavStream`). Remarque : `ffprobe` affiche une durée de
conteneur qui inclut les 0,32 s de pre-skip, alors que le flux décodé dure bien N.

Mesures (le script les refait à chaque exécution) : les deux copies décodées
sont mises bout à bout, puis la jointure est comparée au reste du fichier.
- saut d'échantillon à la jointure, rapporté au 99e centile des sauts ;
- « clic » : énergie de la dérivée seconde sur 5 ms centrées sur la jointure,
  rapportée à son voisinage de ±50 ms et comparée à toutes les fenêtres de 5 ms
  du fichier.

Avec le traitement, l'indicateur de clic à la jointure reste à moins de 1 dB de
sa valeur avant encodage pour les 18 boucles (au plus 1,3 dB, contre 0,4 dB sur
le master, pour `vagues`). Avec l'encodage brut (`--plain-opus`), les musiques
prenaient de +14 à +29 dB à la jointure, et tous les fichiers exigeaient une
coupe de fin. Pour `flute`, `guitare-douce` et `boite-a-musique`, la valeur
élevée vient d'une attaque de note sur le premier temps, présente aussi dans
le master : ce n'est pas un défaut de jointure.

### Loudness

La mesure suit l'ITU-R BS.1770-4 (pondération K, blocs de 400 ms avec 75 % de
recouvrement, porte absolue −70 LUFS, porte relative −10 LU), implémentée
dans le script et appliquée **circulairement** à la boucle. Chaque élément est
d'abord normalisé en crête (−1 dBFS), puis amené à −23 LUFS. Si la crête vraie
(suréchantillonnage ×4) dépasse −1 dBTP, un limiteur circulaire doux
intervient ; aucun élément n'en a eu besoin. Contrôle indépendant : le filtre
`ebur128` de ffmpeg sur les fichiers décodés donne −23,0 ± 0,2 LUFS.

## Icônes et logotype

`generate_icons.js` reprend le SVG de l'icône de la maquette (goutte sur verre
sombre, gouttelettes, paysage inversé dans la goutte). La photo de la maquette
est remplacée par une **scène synthétique dessinée en SVG** : lumière à travers
une forêt de sapins, petite cascade, eau turquoise, berges moussues. Cette scène
sert deux fois, floutée derrière le verre et retournée dans la goutte, comme à
travers une lentille.

- Icône adaptative : le calque d'arrière-plan est le verre sombre avec les
  gouttelettes, étendu à 108 dp pour l'effet de parallaxe ; le premier plan est
  la grande goutte, dans la zone sûre de 66 dp ; le calque monochrome est la
  silhouette blanche de la goutte, avec son reflet évidé.
- Le logotype utilise **Fraunces** (SIL OFL), fichier
  `app/assets/fonts/Fraunces-Variable.ttf`, graisse 500, couleur `#f4f1ea` pour
  fond sombre. Le texte n'est pas vectorisé : `wordmark.svg` charge la police
  par un chemin relatif (`../fonts/Fraunces-Variable.ttf`). Dans Flutter,
  utiliser plutôt `wordmark.png`, ou déclarer la famille Fraunces et dessiner le
  texte. Le point du i est un ı sans point surmonté d'une goutte, placée comme
  dans la maquette (0,54 em au-dessus de la ligne de base).
