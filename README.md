# Eventide

Application Android pour se détendre et s'endormir avec des sons de nature, devant de vrais paysages, que l'on règle du bout du doigt ou à la voix. Nom de travail : la marque « Eventide » reste à vérifier (annexe D du dossier d'analyse).

| Dossier | Contenu |
|---|---|
| [`app/`](app/) | Application **Flutter** (Android d'abord) : interface « Vitre », moteur audio, programmations, assistant vocal, achats, publicité |
| [`backend/`](backend/) | API **Django 5.2 + DRF** : installations, droits et achats Google Play, assistant vocal (routeur, modèle Flash-Lite), partage, adresses de contenu signées |
| [`infra/`](infra/) | **Terraform** : hébergement mutualisé dans le compte AWS principal (`us-east-1`), selon les mêmes règles que Candidature Express : uniquement des ajouts à côté de CINAF et JobMinutes |
| [`docs/`](docs/) | [Journal](docs/journal-de-developpement.md) (état, décisions, questions ouvertes), contrat d’API, architecture de l’app, hébergement, runbooks |
| [`content/`](content/), [`tools/media/`](tools/media/) | Contenus de substitution (sons synthétiques) et scripts de génération |
| [`shared/`](shared/) | Vecteurs de test communs à l'app et à l'API |

Le catalogue fermé (paysages, sons, musiques, décors et limites du gratuit) est **un seul fichier** : [`app/assets/catalog.json`](app/assets/catalog.json), lu par l'app et embarqué par l'API.

## Décisions

- **Flutter** plutôt que Kotlin/Compose (décision du product owner du 28 octobre 2026) : toute l'interface et la logique se vérifient par `flutter analyze` et `flutter test` ; l'iPhone reste possible. Le démarrage programmé à 22 h utilise un peu de Kotlin natif (alarme exacte).
- **PostgreSQL** pour la base (et non DynamoDB comme le proposait le dossier), sur l'instance partagée de CINAF, avec une base et des rôles propres.
- **Intégration AWS identique à Candidature Express** : voir [`docs/infra/hebergement-mutualise.md`](docs/infra/hebergement-mutualise.md). Jamais de `terraform apply` sans l'accord du product owner après relecture du plan.
- Le reste suit le dossier d'analyse v1.6 : local d'abord, IA derrière un routeur (règles sur le téléphone, puis Gemini Flash-Lite en JSON strict), Annuler partout, pas d'images génératives, plafond de 2 € d'IA par abonné et par mois.

## Démarrer

```bash
cd app
flutter pub get
flutter analyze && flutter test
flutter run                      # sans backend : voix par règles seules, achats non vérifiés (debug)
```

Avec l'API locale et les contenus Premium servis en local : voir [`docs/app/architecture.md`](docs/app/architecture.md) et [`backend/README.md`](backend/README.md).

## Ce qui reste à faire hors du code

Photos, sons et musiques sous licence commerciale (les contenus actuels sont des **substituts synthétiques**), compte Google Play au nom de CINAF, vérification de la marque et achat du domaine, essais sur quatre téléphones (démarrage programmé sur 14 nuits, lecture de 8 h écran éteint), jeu de 200 phrases françaises pour la voix, textes juridiques.
