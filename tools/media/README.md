# Médias d'Eventide : outils

Trois familles d'outils :

- `process_video.py` traite les **vidéos de paysages** reçues (générées par le product owner, ou matériel de test) en boucles sans raccord pour l'application, éclairs effacés (section « Vidéos de paysages » ci-dessous) ;
- `make_ambiance.py` fait de leur **bande son** l'ambiance du paysage : une boucle sans raccord d'au moins 60 s, sans tonnerre (section « Ambiances des paysages ») ;
- `generate_audio.py` et `generate_icons.js` génèrent les **médias provisoires** (sons, musiques, variantes du tonnerre, icônes) à partir de rien.

`remote_manifest.py` réécrit `app/assets/landscapes/remote.json` d'après `content/` (vidéos, images, sons et musiques présents sur S3) ; les trois outils l'appellent après avoir écrit dans `content/`.

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
python3 tools/media/generate_audio.py   # 17 boucles, 10 variantes du tonnerre, silence.ogg (~1 min 30 sur 4 cœurs)
node tools/media/generate_icons.js      # logo, icônes Android, logotype
```

Options de `generate_audio.py` :

| Option | Effet |
|---|---|
| `--only vent harpe` | ne régénère que ces identifiants (`--only tonnerre` : toutes les variantes du tonnerre) |
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
sa valeur avant encodage pour les 18 boucles mesurées le 28 octobre 2026, dont l’ancienne boucle de tonnerre (au plus 1,3 dB, contre 0,4 dB sur
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

## Variantes du tonnerre (son à événements, contrat d'API § 11)

`tonnerre` n'est plus une boucle (l'ancienne boucle de 47 s, `tonnerre.ogg`, est supprimée) : l'application joue de temps en temps (toutes les 2 à 5 minutes) une de ses **variantes**, jamais une des deux dernières, avec un léger écart de volume, de vitesse et de position stéréo, et l'éclair du décor juste avant. Les variantes sont des coups uniques, du silence au silence.

**Ce sont des substituts provisoires**, synthétiques (`thunder_event`, dérivé de l'ancienne recette `snd_tonnerre`), **à remplacer** par des tonnerres enregistrés sous licence ou générés (connecteur Higgsfield, par exemple), en gardant les clés `audio/sons/tonnerre-NN.ogg` : 6 à 20 s chacun, fin naturelle jusqu'au silence, −23 LUFS intégrés, crête vraie ≤ −1 dBTP.

Ce qui différencie les variantes (réglages dans `THUNDER_VARIANTS`) : la distance (un tonnerre proche a un claquement déchirant de clics 400 à 4 500 Hz, parfois un « boum » grave, et un grondement plus clair ; un tonnerre lointain est filtré sous 110 à 300 Hz et monte lentement), le nombre de coups (2 à 8), la vitesse du roulement, le déplacement dans l'espace stéréo, les échos (bâtiments, collines) et la réverbération (2 à 5 s). Chaque variante a sa graine (`crc32(id)`). Fin naturelle : décroissance exponentielle après les derniers coups (−32 dB une seconde avant la fin), puis 1 s de fondu. Encodage Opus 64 kbit/s ordinaire (pas de traitement de jointure : ce n'est pas une boucle). Le maître garde 2,5 dB sous la pleine échelle, car Opus fait dépasser les crêtes d'un claquement d'environ 1 dB.

Mesures après décodage (29 octobre 2026) : toutes à −23,0 LUFS intégrés (−22,9 pour 03 et 08), aucun échantillon écrêté, silence numérique à la fin.

| Variante | Caractère | Durée | Taille | Sonie max. (400 ms) | Crête vraie |
|---|---|---|---|---|---|
| tonnerre-01 | proche : claquement, « boum », grondement lourd | 10 s | 56 Kio | −13,8 LUFS | −2,6 dBTP |
| tonnerre-02 | proche, court : double claquement, échos de rue | 7 s | 41 Kio | −14,3 | −1,7 |
| tonnerre-03 | distance moyenne : roulement qui traverse de gauche à droite | 12 s | 73 Kio | −17,9 | −7,2 |
| tonnerre-04 | lointain : long roulement | 16 s | 111 Kio | −18,3 | −5,0 |
| tonnerre-05 | très lointain : grondement grave et doux | 9 s | 81 Kio | −19,9 | −6,3 |
| tonnerre-06 | proche, puis long roulement avec échos | 18 s | 101 Kio | −12,9 | −1,7 |
| tonnerre-07 | moyen : plusieurs coups à la suite | 14 s | 79 Kio | −12,2 | −2,3 |
| tonnerre-08 | lointain : monte puis s'éteint | 11 s | 80 Kio | −18,3 | −5,9 |
| tonnerre-09 | proche et sec, échos de ville | 8 s | 44 Kio | −16,2 | −3,5 |
| tonnerre-10 | lointain, double grondement très long | 20 s | 131 Kio | −18,9 | −6,1 |

La bande son de la vidéo `pluie-ville` contient un vrai coup de tonnerre (3,3 s à 10 s) ; il n'a pas été repris en variante : il est mêlé à la pluie (la retirer laisserait des artefacts) et coupé net par la fin de la vidéo.

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

# Ambiances des paysages (`make_ambiance.py`)

Contrat d'API § 11 : le son d'origine de la vidéo d'un paysage devient un son du catalogue (`ambiance-<paysage>`, champ `paysage`), joué par le mélangeur de l'application en tête du mix par défaut. La vidéo reste muette (la pause coupe le son, l'image continue). Les sources sont courtes (10 s pour Veo) et certaines contiennent du tonnerre, désormais joué à part (`tonnerre`, son à événements). Prérequis : Python 3, numpy, `ffmpeg` avec `libopus` ; le script réutilise la mesure de sonie, la finalisation et l'encodage sans raccord de `generate_audio.py`.

```sh
python3 tools/media/make_ambiance.py                          # les trois ambiances (~1 min)
python3 tools/media/make_ambiance.py --only ambiance-pluie-ville
python3 tools/media/make_ambiance.py --check-only             # refait les mesures sur les fichiers produits
python3 tools/media/make_ambiance.py --wav-dir /tmp/wav --report mesures.json
```

## Chaîne de traitement

1. **Décodage** du premier flux audio (48 kHz stéréo, flottant), 0,1 s retiré à chaque bord.
2. **Grondements retirés** : la bande sous ~460 Hz (séparation complémentaire à phase nulle : les deux bandes redonnent exactement l'original) est ramenée à son propre plancher (20e centile de son niveau sur 100 ms, + 1,5 dB, anticipation de 50 ms) : les roulements lointains disparaissent, le corps de la pluie et de l'eau reste.
3. **Tonnerre repéré** : niveau sur 100 ms de la bande 700-4 000 Hz (le « corps » de la pluie ou de l'eau, stable à ± 1 dB) au-dessus de son plancher de plus de 3 dB, ou bande 25-180 Hz d'origine au-dessus de son plancher de plus de 9 dB (un coup fort) ; chaque détection est élargie de 0,3 s avant et 1 s après (la traîne). Les impacts de gouttes (aigus) ne sont pas du tonnerre et ne sont pas regardés. Le reste est la **réserve sans tonnerre**.
4. **Synthèse de texture** sur un axe circulaire de N échantillons (plus de 60 s, nombre entier de trames Opus de 20 ms) : des grains de 0,8 à 1,8 s (0,5 à 1,1 s pour `pluie-ville`, dont la réserve est petite) tirés au hasard dans la réserve, chacun avec sa vitesse (± 2,5 %, rééchantillonnage par FFT avec marges) et une inversion gauche/droite une fois sur deux, enchaînés par des fondus de 0,3 s à puissance constante (sinus/cosinus). Le dernier grain se fond dans le premier : aucun raccord. Un grain ne reprend jamais la matière des deux grains précédents, ni la suite immédiate du grain précédent (pas d'effet de filtre en peigne). `streams` superpose plusieurs flux indépendants (à puissance égale) : pluie plus dense, plus « torrentielle » (`pluie-ville` : 2).
5. **Niveau** comme toutes les boucles : −23 LUFS (BS.1770-4, circulaire), crête vraie ≤ −1 dBTP.
6. **Encodage** comme toutes les boucles (pré-roulement circulaire, paquets de chauffe, exactement N échantillons), Ogg Opus **96 kbit/s** : de vrais enregistrements de pluie et d'eau sont un bruit dense, plus exigeant que les boucles synthétiques à 64 kbit/s. (La consigne disait Ogg Vorbis ; nous gardons Opus, comme tous les autres sons, pour que le traitement de jointure s'applique et que la boucle tombe juste à l'échantillon.)
7. **Mesures** sur le fichier décodé : durée, sonie, crête vraie, jointure (saut et « clic », mêmes indicateurs que les boucles), tonnerre restant (niveaux sur 100 ms des bandes 25-180 Hz et 180-700 Hz au-dessus de leur médiane, comparés à la source), périodicité (plus forte autocorrélation de l'enveloppe de niveau sur 50 ms, bande 700-4 000 Hz, pour des décalages de 1 à 30 s ; comparée à la réserve simplement bouclée).

Destinations : le catalogue décide (`gratuit`) : `app/assets/audio/sons/<id>.ogg` (gratuit, embarqué) ou `content/audio/sons/<id>.ogg` (Premium, S3) ; le matériel de test de tiers va dans `medias-test/audio/sons/<id>.ogg` seulement (version démo, jamais `content/` ni `app/assets/`). La bande son de `ciel-etoile` est une musique : pas d'ambiance.

## Mesures (29 octobre 2026)

| Ambiance | Source utilisée | Boucle | Taille | Sonie | Crête vraie | Jointure : saut / 99e c. ; clic (rang) | Tonnerre restant : grave / roulement (source) | Périodicité (réserve bouclée) |
|---|---|---|---|---|---|---|---|---|
| `ambiance-cascade-foret` (gratuit) | 9,8 s, aucun tonnerre | 61 s, 47 grains | 649 Kio | −23,0 LUFS | −12,4 dBTP | 0,047 / 0,055 ; 0,0 dB (51 %) | 3,0 / 1,9 dB (2,6 / 1,2) | 0,11 (0,91) |
| `ambiance-pluie-ville` (Premium) | 2,85 s sans tonnerre sur 9,8 s (tonnerre 6,4 s) | 67 s, 2 flux, 168 grains | 794 Kio | −23,0 LUFS | −1,3 dBTP | 0,0045 / 0,046 ; 0,2 dB (55 %) | 5,0 / 3,9 dB (18,2 / 16,4) | 0,08 (1,00) |
| `ambiance-toits-pluie` (test, démo seulement) | 19,2 s sans tonnerre sur 30 s | 71 s, 55 grains | 765 Kio | −23,0 LUFS | −11,1 dBTP | 0,0052 / 0,041 ; −0,3 dB (35 %) | 4,3 / 3,8 dB (17,1 / 13,8) | 0,10 (0,90) |

Lecture :
- **Jointure** : chaque fichier se décode en exactement N échantillons (aucune coupe de fin). Le « clic » à la jointure est au niveau d'une fenêtre ordinaire du fichier (rang 35 à 55 %, loin du 99e centile) : rien ne marque l'endroit où la boucle recommence. Le saut d'échantillon de `cascade-foret` est élevé en valeur relative (rang 97 %) parce que la cascade est un bruit très dense partout ; il reste sous le 99e centile.
- **Tonnerre** : dans la source, les bandes graves montaient de 16 à 18 dB au-dessus de leur médiane pendant le tonnerre ; dans l'ambiance, de 4 à 5 dB au plus, comme les fluctuations ordinaires de la pluie (la cascade, sans tonnerre, est à 2 à 3 dB).
- **Périodicité** : la réserve simplement bouclée se répète (autocorrélation de 0,90 à 1,00) ; la texture recomposée n'a plus de période (0,08 à 0,11). La même matière revient au hasard : pour `pluie-ville`, la réserve ne fait que 2,85 s, la même matière revient en moyenne toutes les 1,6 s, mais jamais au même endroit ni à la même vitesse, et les deux flux superposés ne sont jamais les mêmes ensemble.
- **Spectre** : l'équilibre des fréquences de la source est gardé (± 0,6 dB par bande d'octave pour la cascade ; pour la pluie, environ −2 dB sous 250 Hz, où le grondement a été retiré).

# Vidéos de paysages (`process_video.py`)

Transforme une vidéo brute (Veo dans Gemini, ou matériel de test) en ce que l'application affiche derrière ses panneaux de verre : un **paysage vivant**, jamais un lecteur vidéo. Prérequis : Python 3, numpy, Pillow, `ffmpeg`/`ffprobe` avec `libx264`. Les fichiers vidéo sont des données non fiables : ils ne sont lus que par ffmpeg et ffprobe.

```sh
python3 tools/media/process_video.py                    # tous les paysages (~6 min sur 4 cœurs)
python3 tools/media/process_video.py --only pluie-ville
python3 tools/media/process_video.py --check-only       # refait les mesures sur les fichiers produits
python3 tools/media/process_video.py --sheets /tmp/planches --report mesures.json
```

`--sheets` écrit des planches de contrôle : `<id>-join.png` (les 3 images avant et les 3 après le raccord de la boucle) et `<id>-fade.png` (le fondu). La liste des paysages et leurs réglages sont dans `ITEMS`, en tête du script.

## Chaîne de traitement

1. **Décodage** du seul flux vidéo (son et image de couverture ignorés), en yuv420p, sans aucune conversion de couleur : tout le traitement se fait sur les plans Y, U, V (numpy), sans aller-retour RVB.
2. Facultatif : **recadrage** au centre en 9:16 (jamais agrandi, jamais de bandes noires) et **étalonnage** (gain et gamma sur la luminance, saturation réduite, légère teinte).
3. **Éclairs** : un éclair est un pic de la luminance moyenne d'une image au-dessus d'un plancher glissant (20e centile sur ± 2 s), de plus de 2 niveaux. Deux traitements :
   - `remove_flashes` (`pluie-ville`, depuis le 29 octobre 2026) : **les éclairs sont effacés**, car l'application les dessine elle-même juste avant chaque tonnerre (contrat d'API § 11). Chaque image d'un éclair (avec 2 images de marge) est refaite à partir du fondu des deux images calmes qui l'encadrent (Y, U et V). L'écart avec ce fondu est séparé en une partie lisse (flou en boîte de rayon 12 px : la lueur du ciel) et une partie fine. La lueur est retirée ; les éclairs eux-mêmes et les gouttes qu'ils allument (détail plus clair de 14 niveaux, masque élargi de 3 px) prennent la référence ; ailleurs, là où la lueur ne porte pas (la ville en bas), l'image garde son propre détail (± 6 niveaux) : l'image ne se fige pas. La lueur est estimée sans les éclairs (convolution normalisée), sans quoi un contour sombre restait à leur place ;
   - `soften_flashes` (ancien traitement, gardé dans le script) : la montée de lumière est comprimée en douceur (vers + 15 % du plancher, au plus + 6 % par image), pixel par pixel ; l'éclair reste visible, adouci.
4. **Choix du segment** : `full` (toute la source, ou l'intervalle `span` donné quand la source a un défaut), `avoid-flashes` (la boucle la plus longue dont les deux fenêtres de fondu ne contiennent aucun éclair, avec 2 images de marge : un éclair n'est jamais coupé en deux par le fondu), `fewest-flashes` (boucle d'au moins `min_loop_s`, fenêtres de fondu calmes, et le moins d'images d'éclair à refaire ; puis la plus longue), `best-match` (durée de boucle dans un intervalle, fenêtres choisies là où les deux moments se ressemblent le plus sur une luminance floutée, pour éviter les images fantômes).
5. **Boucle** : les F dernières images sont fondues sur les F premières (poids linéaires (j+1)/(F+1)) ; la sortie a N − F images et la dernière image s'enchaîne sur la première comme deux images voisines de la source.
6. **Encodage** H.264 High, yuv420p, cadence de la source, image clé toutes les 2 s, **sans images B** (pas de liste d'édition, pas de réordonnancement : l'image 0 est la première décodée), `+faststart`, sans son ni métadonnées ; matrice de couleur de la source (BT.601 pour Veo, BT.709 pour les vidéos de test), primaires et transfert BT.709. Le CRF est le plus bas (18 au mieux) qui tient dans 2,5 Mo (4 Mo pour la pluie de test). `x264` en 4 fils fixes : même résultat à chaque exécution.
7. **Image fixe** : l'image 0 de la vidéo **encodée**, redécodée (matrice de la source, plage limitée vers pleine), en JPEG qualité 85 : le passage image fixe → vidéo dans l'application est identique au pixel près (aux arrondis JPEG près).
8. **Mesures** : la vidéo produite est redécodée ; le raccord (écart absolu moyen de luminance entre la dernière et la première image) est comparé aux écarts entre images voisines de toute la boucle, et aux sauts vers chaque image clé.

## Destinations

| Cas | Vidéo | Image fixe |
|---|---|---|
| Paysage gratuit (`catalog.json`) | `app/assets/landscapes/<id>.mp4` | `app/assets/landscapes/<id>.jpg` |
| Paysage Premium | `content/videos/paysages/<id>.mp4` (S3) | `content/images/paysages/<id>.jpg` (S3) |
| Matériel de test de tiers (non diffusable) | `medias-test/videos/paysages/<id>.mp4` | `medias-test/images/paysages/<id>.jpg` |

Le script réécrit aussi `app/assets/landscapes/remote.json` (`remote_manifest.py` : paysages Premium qui ont une vidéo ou une image sur S3, sons et musiques présents dans `content/`) : l'application ne demande jamais une clé absente. Les originaux restent inchangés dans `medias-bruts/videos/<id>.mp4` (et `medias-test/originaux/` pour le matériel de test).

## Mesures (28 octobre 2026)

Écarts absolus moyens de luminance (0–255). « Raccord » : dernière → première image après encodage ; « avant encodage » : la même mesure sur la boucle avant compression.

| Paysage | Boucle | Taille | CRF | Raccord | Voisines (médiane / 95e c.) | Sauts vers les images clés | Avant encodage : raccord / médiane | Raccord brut de la source |
|---|---|---|---|---|---|---|---|---|
| `cascade-foret` | 5,875 s, 141 images, 720 × 1280, 24 i/s | 2,33 Mo | 24 | 4,38 | 1,86 / 3,02 | 3,63 | 2,56 / 1,92 | 10,37 |
| `pluie-ville` (29 octobre, éclairs effacés) | 7,625 s, 183 images, 720 × 1280, 24 i/s | 1,73 Mo | 18 | 0,94 | 0,43 / 0,81 | 0,81 | 0,55 / 0,44 | 11,55 |
| `toits-pluie` (test) | 13,0 s, 391 images, 480 × 854, 30 i/s | 3,98 Mo | 25 | 10,44 | 13,47 / 16,77 | 14,95 | 9,99 / 13,52 | 22,49 |
| `ciel-etoile` (test) | 15,6 s, 468 images, 404 × 720, 30 i/s | 0,84 Mo | 18 | 0,53 | 0,18 / 0,33 | 0,48 | 0,15 / 0,17 | 2,85 |

Lecture : **avant encodage, le raccord est au niveau du mouvement normal** entre deux images voisines. Après encodage, il vaut un saut vers une image clé (l'image 0 est une image clé, plus nette que les images prédites qui la précèdent) : le même petit « respir » de netteté se produit toutes les 2 s dans toute la boucle, le raccord ne s'en distingue pas. Images fixes : écart moyen avec l'image 0 décodée de 0,6 à 1,9 niveau (JPEG qualité 85), 13 à 208 ko.

Particularités des sources :

- `cascade-foret` : la source Veo a une **discontinuité de génération** entre ses images 62 et 63 (toute l'image saute : écart 10,4 contre 1,9 ailleurs, puis 4,0). Seules les images 63 à 239 sont utilisées (`span`), d'où une boucle de 5,9 s au lieu de 8,5 s.
- `pluie-ville` : **sept éclairs en 10 s** dans la source (luminance moyenne de 57 jusqu'à 116, avec des éclairs visibles). Aucun passage calme de plus de 1,5 s : toute boucle de 7 s en contient. Segment `fewest-flashes` avec `min_loop_s` 7 (aussi longue qu'avant) : images 26 à 227 de la source, fondu de 19 images (0,79 s) dans des passages calmes ; 4 éclairs dans la boucle, **88 images sur 183 refaites** (images 45-53, 79-103, 112-121 et 152-195 de la source ; les éclairs et gouttes allumées couvrent jusqu'à 14,6 % de l'image). Mesures, saut maximal de la luminance moyenne d'une image à la suivante : **46,0 niveaux dans la source → 0,35 avant encodage, 0,32 après encodage (raccord compris)** ; pic de luminance moyenne des éclairs de 95,7-116,4 à 57,3-57,7 (plancher 57) ; écart maximal au plancher 0,76 niveau. Contrôle visuel : plus d'éclair ni de contour, les gouttes restent en place ; pendant les images refaites, le ciel et les gouttes du haut passent en fondu (mouvement légèrement ralenti, jusqu'à 1,8 s), la ville garde son mouvement. La boucle est plus légère (1,73 Mo au lieu de 2,28 Mo : plus de flashs à coder).
- `toits-pluie` (test) : pluie forte partout (écart de 13 entre images voisines) ; segment de 13 s choisi où les feuilles reviennent à la même position.
- `ciel-etoile` (test) : nébuleuse jaune-orange très lumineuse (luminance moyenne 128) assombrie et désaturée vers un ciel de nuit bleu ardoise (moyenne 43, tiers inférieur 30), recadrée de 480 × 720 en 404 × 720 (9:16) ; segment de 15,6 s, fondu de 2 s.

Si ExoPlayer marquait un accroc au moment où la boucle recommence, `copies=2` dans `ITEMS` enchaîne deux boucles dans le même fichier (deux fois moins de reprises, deux fois plus lourd).

