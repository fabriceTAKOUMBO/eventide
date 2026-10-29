# Vidéos de paysages — consignes et prompts

Une vidéo par paysage du catalogue, générée par un modèle vidéo (Veo dans Gemini, ou Veo/Kling via Figma Weave), puis traitée par nous : boucle sans raccord, compression, image fixe extraite pour la veille et les vignettes. **Le son de la vidéo compte** : il devient l'« ambiance » du paysage (contrat d'API § 11), une boucle d'au moins 60 s jouée par le mélangeur de l'app (la vidéo, elle, reste muette dans l'app : la pause coupe le son, l'image continue).

## Règles communes (à respecter pour chaque vidéo)

- **Format vertical 9:16**, 1080 × 1920 au minimum (le Galaxy S24 affiche 1080 × 2340 ; l'app recadre légèrement).
- **Caméra fixe**, sans zoom ni travelling : seul le paysage bouge (eau, pluie, nuages, feuillage). C'est ce qui permet une boucle sans raccord visible.
- **Mouvement lent et régulier**, rien de soudain, lumière stable du début à la fin.
- **Aucun éclair dans l'image** : l'application dessine elle-même les éclairs, juste avant chaque coup de tonnerre (décor « Éclairs lointains »). Un éclair filmé arriverait sans tonnerre ; nous devons alors l'effacer, ce qui fige l'image le temps de l'éclair.
- **Aucune personne, aucun animal en gros plan, aucun texte, aucun logo, aucun filigrane.**
- **Photographique**, pas de dessin ni d'effet « IA » trop lisse ; tons sombres et doux pour que le texte blanc de l'app reste lisible, surtout dans le **tiers inférieur** (le menu y est posé).
- **Durée : 30 secondes au moins** (plus c'est long, moins la boucle se voit et plus l'ambiance sonore a de matière).
- **Garder la bande son**, sans musique ni voix : le bruit du paysage lui-même (pluie, eau, vent, ville au loin), régulier, **sans tonnerre** (le tonnerre est un son à part, joué de temps en temps par l'app, jamais deux fois pareil). Si l'outil ne génère pas de son, le signaler : l'ambiance sera alors faite autrement.
- Garder la preuve de l'outil et des conditions d'usage commercial (dossier, section 9).

Gabarit à ajouter à la fin de chaque prompt :

> Vertical 9:16 video, at least 30 seconds, locked-off static camera, no camera movement, no zoom, photorealistic nature footage, calm slow continuous motion, consistent lighting from start to end, no lightning flashes, seamless loopable, no people, no text, no logo, no watermark, darker lower third, cinematic but natural colors. Keep the natural ambient soundtrack of the scene (rain, water, wind), steady, no music, no voices, no thunder.

## Prompts par paysage

| Identifiant | Prompt (en anglais, mieux compris par les modèles) |
|---|---|
| `cascade-foret` | A tall waterfall falling into a clear green pool in a dense mossy forest, ferns in the foreground, soft mist rising, gentle diffused daylight. |
| `sous-bois` | Sunlit forest undergrowth, tall straight tree trunks, sunbeams through the canopy, light breeze moving leaves and grass, floating dust in the light. |
| `berge-mousseuse` | A quiet stream between moss-covered banks, small stones in slow-flowing clear water, ferns, soft overcast light. |
| `torrent-montagne` | A mountain torrent rushing over rocks in an alpine valley, pine forest and distant snowy peaks, cool morning light. |
| `pierres-eau` | Close view of smooth river stones with shallow clear water flowing over them, small ripples and reflections, calm. |
| `lisiere-verte` | Edge of a forest opening onto a green meadow, tall grass swaying slowly in the wind, a large tree, soft late-afternoon light. |
| `pluie-ville` | Heavy rain over a city at night seen from a window, blurred warm street lights and windows, rain streaks, reflections on wet streets, dark stormy sky without lightning. Soundtrack: steady heavy rain on the window and the city, no thunder. |
| `cafe-nuit` | Inside a cozy dimly lit café at night, rain running down the large window, warm bokeh lights outside, steam rising from a cup on a wooden table. |
| `toits-pluie` | Heavy rain falling on old corrugated metal roofs at dusk, water dripping from the roof edges, dark stormy clouds without lightning. Soundtrack: heavy rain drumming on the metal roof, no thunder. (Ambiance de la référence « chuva no telhado de zinco ».) |
| `ciel-etoile` | A clear night sky full of stars and the Milky Way above a dark tree-line silhouette, very slow star movement, faint passing clouds. (Ambiance de la référence « Mystery of the Universe ».) |
| `aurore-boreale` | Green and violet northern lights slowly waving above a snowy mountain lake at night, reflections on the calm water, stars. |
| `lune-lac` | A full moon over a still lake at night, a silvery moonlight path shimmering on the water, pine silhouettes, light mist. |

## Après génération

Déposer les fichiers MP4 dans `medias-bruts/videos/` (GitHub, branche de travail) ou les joindre dans la conversation, nommés par identifiant (`toits-pluie.mp4`…). Le traitement (boucle, compression, image fixe) est fait par nous ; la vidéo ne joue que lorsque l'écran est allumé et l'app au premier plan, l'image fixe prend le relais en veille et si « réduire les animations » est activé.

Le traitement est fait par `tools/media/process_video.py` (détails et mesures dans `tools/media/README.md`) : boucle sans raccord par fondu enchaîné, son retiré de la vidéo, éclairs effacés, compression à 2,5 Mo au plus, image fixe = première image de la boucle. La bande son devient l'ambiance du paysage par `tools/media/make_ambiance.py` : le tonnerre en est retiré, puis une boucle sans raccord d'au moins 60 s est recomposée à partir des passages sans tonnerre.

### Ce que nous ont appris les deux premières vidéos (28 octobre 2026)

- **Résolution** : Gemini a rendu du 720 × 1280. Sur le Galaxy S24, l'image est agrandie 1,83 fois : correcte, un peu douce. Demander du 1080 × 1920 quand l'outil le permet.
- **Durée utile** : la boucle perd la durée du fondu (≈ 1,5 s) et tout passage à défaut. Une source de 10 s donne 6 à 8,5 s de boucle ; viser 12 s ou plus.
- **Défauts de génération** : `cascade-foret` a un saut brusque de toute l'image à 2,6 s (raccord entre deux morceaux générés) ; nous l'avons écarté, la boucle ne dure que 5,9 s. Vérifier la vidéo image par image avant de nous l'envoyer si possible, ou la régénérer.
- **Éclairs** : `pluie-ville` en avait sept en 10 s, très lumineux. Depuis le 29 octobre 2026, ils sont effacés de la vidéo (l'app les dessine avant chaque tonnerre) : 88 images sur 183 ont dû être reconstituées. Demander **aucun éclair** dans le prompt.
- **Son** : la vidéo avait sa propre bande son (pluie, puis un coup de tonnerre à 3,3 s qui dure jusqu'à la fin). Seules les 3 premières secondes sont sans tonnerre : l'ambiance est recomposée à partir de ce peu de matière. Une source de 30 s sans tonnerre donnerait une ambiance bien plus riche.

