# Vidéos de paysages — consignes et prompts

Une vidéo par paysage filmé du catalogue (rubriques Nature et Urbain), générée par un modèle vidéo (FLUX 3 Video dans Higgsfield depuis le 30 octobre 2026 ; auparavant Veo dans Gemini), puis traitée par nous : boucle sans raccord, compression, image fixe extraite pour la veille et les vignettes. **Le son de la vidéo compte** : il devient l'« ambiance » du paysage (contrat d'API § 11), une boucle d'au moins 60 s jouée par le mélangeur de l'app (la vidéo, elle, reste muette dans l'app : la pause coupe le son, l'image continue).

## Règles communes (à respecter pour chaque vidéo)

- **Format vertical 9:16**, 1080 × 1920 au minimum (le Galaxy S24 affiche 1080 × 2340 ; l'app recadre légèrement).
- **Caméra fixe**, sans zoom ni travelling : seul le paysage bouge (eau, pluie, nuages, feuillage). C'est ce qui permet une boucle sans raccord visible.
- **Mouvement lent et régulier**, rien de soudain, lumière stable du début à la fin.
- **Aucun éclair dans l'image** : l'application dessine elle-même les éclairs, juste avant chaque coup de tonnerre, sur les paysages marqués `eclairs: true`. Un éclair filmé arriverait sans tonnerre ; nous devons alors l'effacer, ce qui fige l'image le temps de l'éclair.
- **Aucune personne, aucun animal en gros plan, aucun texte, aucun logo, aucun filigrane.**
- **Photographique**, pas de dessin ni d'effet « IA » trop lisse ; tons sombres et doux pour que le texte blanc de l'app reste lisible, surtout dans le **tiers inférieur** (le menu y est posé).
- **Durée : la plus longue possible**, 20 s avec Higgsfield (plus c'est long, moins la boucle se voit et plus l'ambiance sonore a de matière).
- **Garder la bande son**, sans musique ni voix : le bruit du paysage lui-même (pluie, eau, vent, ville au loin), régulier, **sans tonnerre** (le tonnerre est un son à part, joué de temps en temps par l'app, jamais deux fois pareil). Si l'outil ne génère pas de son, le signaler : l'ambiance sera alors faite autrement.
- Garder la preuve de l'outil et des conditions d'usage commercial (dossier, section 9).

## Prompts Higgsfield (30 octobre 2026)

Neuf vidéos : cinq urbaines, quatre de nature. Elles remplacent les deux médias de test tirés de YouTube (`toits-pluie`, `ciel-etoile`, à remplacer avant toute bêta), refont `pluie-ville` (10 s, éclairs à effacer) et `cascade-foret` (boucle de 5,9 s), et ajoutent cinq paysages filmés. Les identifiants nouveaux (`cafe-nuit`, `rue-pavee`, `verriere-pluie`, `pluie-foret`, `vagues-crepuscule`) entrent dans le catalogue et le contrat (§ 12) au moment de l'intégration, pas avant.

**Réglages** : modèle **FLUX 3 Video** (sinon Seedance 2.0), durée **20 s** (le maximum), format **9:16**, **1080p**, **son activé**. Coller le prompt entier : chacun contient déjà les règles communes. Commencer par `toits-pluie` pour juger le coût en crédits et la qualité avant de lancer les autres. Ordre conseillé : `toits-pluie`, `ciel-etoile`, `pluie-ville`, `cascade-foret`, puis les nouveaux.

Fin commune (déjà incluse dans chaque prompt) :

> Vertical 9:16, 20 seconds, 1080p. Locked-off tripod shot: no camera movement, no zoom, no pan. Photorealistic, natural muted colors, subtle film grain, not over-smooth. Slow, steady, continuous motion with identical lighting from the first to the last frame, seamlessly loopable. Darker lower third of the frame. No people, no text, no readable signs, no logos, no watermark. No lightning, no flashes.

Le son est décrit à part dans chaque prompt et finit toujours par : *natural ambient sound only, steady, no music, no voices, no thunder* (l'app joue elle-même les orages ; les paysages `eclairs: true` y ajoutent l'éclair dessiné).

### Urbain

| Identifiant | Scène | Prompt (sans la fin commune) |
|---|---|---|
| `toits-pluie` | Toits sous la pluie | Night, heavy steady rain falling on old zinc and slate rooftops of a European old town, seen from a high attic window. Rain bouncing on the metal, thin streams running down the roof slopes, an overflowing gutter dripping in the foreground, a few warm amber windows glowing in the distance, chimneys, low dark blue-grey clouds. Sound: rain drumming on zinc, gurgling gutters and drips, a faint distant city hum. |
| `cafe-nuit` | Vitre de café la nuit | Inside an empty, dimly lit café at night, looking out through a large window streaked with rain. Raindrops sliding down the glass, blurred warm street lights outside as soft bokeh, a steaming ceramic cup on a dark wooden table in the lower foreground, steam rising slowly. Sound: soft rain tapping on the glass, muffled street ambience, no clinking. |
| `rue-pavee` | Rue pavée à l'heure bleue | A narrow cobblestone street in an old European town at blue hour, light rain falling, wet cobblestones reflecting the warm glow of old street lamps, closed shutters, stone facades, a few lit windows, puddles rippling under the drops, deep blue sky. Sound: light rain on cobblestones and puddles, drips from the eaves, a distant soft city murmur. |
| `pluie-ville` | Pluie sur la ville | Heavy rain over a big city at night seen through a tall apartment window, rain streaks and drops on the glass in the foreground, the city out of focus behind: warm and cool lights, blurred towers, wet avenues glowing far below, low clouds lit orange by the city. Sound: steady heavy rain against the window and over the city, a distant low traffic hum, no sirens, no horns. |
| `verriere-pluie` | Verrière sous la pluie | Looking straight up through a large old glass skylight at night during steady rain, raindrops landing and running across the glass in slow rivulets, the dark iron frame of the skylight in silhouette, a dark sky with faint moving clouds softly lit by the city glow. Sound: rain pattering and drumming on the glass, close and enveloping, soft drips. |

### Nature

| Identifiant | Scène | Prompt (sans la fin commune) |
|---|---|---|
| `cascade-foret` | Cascade en forêt | A tall waterfall falling into a clear emerald pool in a dense mossy forest, ferns and wet rocks in the foreground, fine mist rising and drifting slowly, soft diffused daylight after rain. Sound: continuous waterfall and splashing water, a light breeze in the leaves, no birdsong. |
| `pluie-foret` | Pluie en forêt | Steady rain in an old forest of tall trees, ferns and moss, raindrops falling through soft green light, drops hitting leaves and moss, small puddles rippling on the forest floor, light mist between the trunks, overcast daylight. Sound: steady rain on leaves and the forest floor, drips from the canopy, no birdsong. |
| `vagues-crepuscule` | Vagues au crépuscule | Calm ocean waves rolling slowly onto a wide sandy beach at dusk, seen from the shore at low height, foam spreading and retreating on the wet sand, the foreground sand already in shadow, a soft sky fading from peach to deep blue, the horizon in the upper third. Sound: regular gentle waves breaking and washing up the sand, soft wind. |
| `ciel-etoile` | Ciel étoilé | A clear moonless night sky full of stars, the Milky Way arching above a dark meadow and a silhouetted tree line, stars turning very slowly, a thin faint cloud drifting, tall grass in the foreground moving gently in the breeze. Sound: soft crickets and a light night breeze in the grass. |

Les prompts des anciens paysages (`sous-bois`, `berge-mousseuse`, `torrent-montagne`, `pierres-eau`, `lisiere-verte`, `aurore-boreale`, `lune-lac`) sont retirés : ces paysages ont quitté le catalogue ou sont devenus des scènes 3D de la rubrique Imaginaire.

## Après génération

Les vidéos générées dans Higgsfield sont récupérées directement par nous grâce au connecteur (lecture des générations, sans rien téléverser) : il suffit de dire lesquelles garder. À défaut, déposer les MP4 dans `medias-bruts/videos/` ou les joindre dans la conversation, nommés par identifiant (`toits-pluie.mp4`…). Le traitement (boucle, compression, image fixe) est fait par nous ; la vidéo ne joue que lorsque l'écran est allumé et l'app au premier plan, l'image fixe prend le relais en veille et si « réduire les animations » est activé.

Le traitement est fait par `tools/media/process_video.py` (détails et mesures dans `tools/media/README.md`) : boucle sans raccord par fondu enchaîné, son retiré de la vidéo, éclairs effacés, compression à 2,5 Mo au plus, image fixe = première image de la boucle. La bande son devient l'ambiance du paysage par `tools/media/make_ambiance.py` : le tonnerre en est retiré, puis une boucle sans raccord d'au moins 60 s est recomposée à partir des passages sans tonnerre.

### Ce que nous ont appris les deux premières vidéos (28 octobre 2026)

- **Résolution** : Gemini a rendu du 720 × 1280. Sur le Galaxy S24, l'image est agrandie 1,83 fois : correcte, un peu douce. Demander du 1080 × 1920 quand l'outil le permet.
- **Durée utile** : la boucle perd la durée du fondu (≈ 1,5 s) et tout passage à défaut. Une source de 10 s donne 6 à 8,5 s de boucle ; viser 12 s ou plus.
- **Défauts de génération** : `cascade-foret` a un saut brusque de toute l'image à 2,6 s (raccord entre deux morceaux générés) ; nous l'avons écarté, la boucle ne dure que 5,9 s. Vérifier la vidéo image par image avant de nous l'envoyer si possible, ou la régénérer.
- **Éclairs** : `pluie-ville` en avait sept en 10 s, très lumineux. Depuis le 29 octobre 2026, ils sont effacés de la vidéo (l'app les dessine avant chaque tonnerre) : 88 images sur 183 ont dû être reconstituées. Demander **aucun éclair** dans le prompt.
- **Son** : la vidéo avait sa propre bande son (pluie, puis un coup de tonnerre à 3,3 s qui dure jusqu'à la fin). Seules les 3 premières secondes sont sans tonnerre : l'ambiance est recomposée à partir de ce peu de matière. Une source de 30 s sans tonnerre donnerait une ambiance bien plus riche.

