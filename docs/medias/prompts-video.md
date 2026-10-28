# Vidéos de paysages — consignes et prompts

Une vidéo par paysage du catalogue, générée par un modèle vidéo (Veo dans Gemini, ou Veo/Kling via Figma Weave), puis traitée par nous : boucle sans raccord, son retiré (le son vient du mélangeur de l'app), compression, image fixe extraite pour la veille et les vignettes.

## Règles communes (à respecter pour chaque vidéo)

- **Format vertical 9:16**, 1080 × 1920 au minimum (le Galaxy S24 affiche 1080 × 2340 ; l'app recadre légèrement).
- **Caméra fixe**, sans zoom ni travelling : seul le paysage bouge (eau, pluie, nuages, feuillage). C'est ce qui permet une boucle sans raccord visible.
- **Mouvement lent et régulier**, rien de soudain (sauf éclairs lointains, rares), lumière stable du début à la fin.
- **Aucune personne, aucun animal en gros plan, aucun texte, aucun logo, aucun filigrane.**
- **Photographique**, pas de dessin ni d'effet « IA » trop lisse ; tons sombres et doux pour que le texte blanc de l'app reste lisible, surtout dans le **tiers inférieur** (le menu y est posé).
- Durée : 8 à 20 secondes. Le son de la vidéo sera retiré.
- Garder la preuve de l'outil et des conditions d'usage commercial (dossier, section 9).

Gabarit à ajouter à la fin de chaque prompt :

> Vertical 9:16 video, locked-off static camera, no camera movement, no zoom, photorealistic nature footage, calm slow continuous motion, consistent lighting from start to end, seamless loopable, no people, no text, no logo, no watermark, darker lower third, cinematic but natural colors.

## Prompts par paysage

| Identifiant | Prompt (en anglais, mieux compris par les modèles) |
|---|---|
| `cascade-foret` | A tall waterfall falling into a clear green pool in a dense mossy forest, ferns in the foreground, soft mist rising, gentle diffused daylight. |
| `sous-bois` | Sunlit forest undergrowth, tall straight tree trunks, sunbeams through the canopy, light breeze moving leaves and grass, floating dust in the light. |
| `berge-mousseuse` | A quiet stream between moss-covered banks, small stones in slow-flowing clear water, ferns, soft overcast light. |
| `torrent-montagne` | A mountain torrent rushing over rocks in an alpine valley, pine forest and distant snowy peaks, cool morning light. |
| `pierres-eau` | Close view of smooth river stones with shallow clear water flowing over them, small ripples and reflections, calm. |
| `lisiere-verte` | Edge of a forest opening onto a green meadow, tall grass swaying slowly in the wind, a large tree, soft late-afternoon light. |
| `pluie-ville` | Gentle rain over a city at night seen from a window, blurred warm street lights and windows, rain streaks, reflections on wet streets. |
| `cafe-nuit` | Inside a cozy dimly lit café at night, rain running down the large window, warm bokeh lights outside, steam rising from a cup on a wooden table. |
| `toits-pluie` | Heavy rain falling on old corrugated metal roofs at dusk, water dripping from the roof edges, distant soft lightning in the clouds now and then. (Ambiance de la référence « chuva no telhado de zinco ».) |
| `ciel-etoile` | A clear night sky full of stars and the Milky Way above a dark tree-line silhouette, very slow star movement, faint passing clouds. (Ambiance de la référence « Mystery of the Universe ».) |
| `aurore-boreale` | Green and violet northern lights slowly waving above a snowy mountain lake at night, reflections on the calm water, stars. |
| `lune-lac` | A full moon over a still lake at night, a silvery moonlight path shimmering on the water, pine silhouettes, light mist. |

## Après génération

Déposer les fichiers MP4 dans `medias-bruts/videos/` (GitHub, branche de travail) ou les joindre dans la conversation, nommés par identifiant (`toits-pluie.mp4`…). Le traitement (boucle, compression, image fixe) est fait par nous ; la vidéo ne joue que lorsque l'écran est allumé et l'app au premier plan, l'image fixe prend le relais en veille et si « réduire les animations » est activé.
