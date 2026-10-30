# Runbook — Mise en service du tableau de bord (publication de contenu)

| | |
|---|---|
| **Quand l'utiliser** | Pour ouvrir le tableau de bord `https://<domaine>/tableau/` ([contrat § 14](../api/contrat-v1.md)) : publier des paysages filmés, des sons et des musiques sans nouvelle version de l'application. |
| **Qui** | Le product owner (administrateur du compte AWS, du projet Google Cloud et du dépôt GitHub). |
| **Prérequis** | Phase 2 faite ([premier déploiement § 11](premier-deploiement.md#11-phase-2--domaine-entrée-publique-google-play)) : domaine, service `api` en marche. Code du tableau de bord fusionné (API et image avec ffmpeg). |
| **Durée** | 30 à 45 minutes. |
| **Règle d'or** | **Aucun `apply` sans le contrôle `check-plan-additions-only.sh` vert ET votre accord après relecture du plan** ([encadré du premier déploiement](premier-deploiement.md#avant-chaque-apply--contrôle-et-relecture-obligatoires)). CINAF, JobMinutes et Candidature Express ne doivent pas être touchées. |
| **Ce que cela ajoute** | Uniquement des ressources d'Eventide ([ADR § 12](../infra/hebergement-mutualise.md#12-tableau-de-bord-et-publication-de-contenu-30-octobre-2026)) : la tâche de traitement `ev-prod-media`, trois rôles IAM, le secret `eventide/prod/admin-emails`, une règle CORS sur notre bucket de contenu. Aucune nouvelle règle sur le répartiteur de charge de CINAF, aucun nouveau certificat, aucun nouveau nom d'hôte. |

## 1. Décisions à prendre avant

Elles sont détaillées dans l'[ADR § 12.7](../infra/hebergement-mutualise.md#127-décisions-du-product-owner-avant-lapply). Le code applique les choix proposés ci-dessous ; dites-le si vous en voulez un autre avant le plan.

- [ ] **Puissance de calcul** : la tâche de traitement utilise 1 vCPU pendant 5 à 15 minutes par fichier. Le quota de vCPU Fargate est commun avec CINAF, JobMinutes et Candidature Express : le budget d'Eventide passe de 2 à **3 vCPU** en production (2,5 en préproduction). Lire d'abord le quota (commande du [premier déploiement § 4](premier-deploiement.md#4-configuration-de-la-pile-et-vérifications-en-lecture-seule)).
- [ ] **Connexions à la base partagée** : toujours **14 au plus** pour Eventide ; la répartition passe de 10 / 2 / 2 à **11 / 2 / 1** (une connexion pour la tâche de traitement, une de moins pour la sauvegarde, qui n'en utilise qu'une).
- [ ] **Coût sur la NAT de CINAF** à leur signaler : environ 0,3 à 0,45 USD par mois pour 20 fichiers envoyés, plus environ 3,5 USD par mois si ffmpeg alourdit l'image de 0,1 Go (environ 1 USD avec un ffmpeg réduit).

## 2. Créer le client OAuth Google « Application Web »

Le bouton « Se connecter avec Google » du tableau de bord a besoin de son propre client OAuth, de type **Application Web**, dans le projet Google Cloud de l'application.

1. [Google Cloud Console](https://console.cloud.google.com/) → projet de Full Relax → **API et services** → **Identifiants**.
2. **Créer des identifiants** → **ID client OAuth** → type **Application Web**, nom « Full Relax — tableau de bord ».
3. **Origines JavaScript autorisées** : `https://<domaine>` et `https://www.<domaine>` (préproduction, si elle existe : `https://preprod.<domaine>`). Exactement ces adresses : `https`, sans chemin ni barre finale.
4. **URI de redirection autorisés** : `https://<domaine>/tableau/connexion` (sert seulement si le bouton fonctionne en mode redirection ; sans danger sinon).
5. **Créer**, puis copier l'**ID client** (`<numéro>-<code>.apps.googleusercontent.com`). C'est une valeur publique ; le **code secret du client n'est pas utilisé** : ne le copiez nulle part.
6. Écran de consentement OAuth : déjà configuré pour la connexion de l'application ; vérifier que le nom affiché est « Full Relax ». Le tableau de bord ne demande que l'adresse e-mail et le profil (aucune validation de Google nécessaire).

## 3. Déclarer le client dans Terraform

Dans `infra/terraform/envs/shared-prod/terraform.tfvars` (jamais dans git) :

```hcl
google_web_client_id    = "<numéro>-<code>.apps.googleusercontent.com"
google_oauth_client_ids = [
  "<identifiant déjà présent pour l'application>",
  "<numéro>-<code>.apps.googleusercontent.com", # le même que google_web_client_id
]
```

L'identifiant doit figurer **aux deux endroits** : le plan s'arrête sinon (« google_web_client_id doit aussi figurer dans google_oauth_client_ids »), car l'API vérifie le jeton de connexion avec cette liste.

## 4. Plan, contrôle, relecture, apply

```bash
cd infra/terraform/envs/shared-prod
aws sso login --profile principal && export AWS_PROFILE=principal AWS_REGION=us-east-1
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json
bash ../../../.github/scripts/check-plan-additions-only.sh tfplan.json
```

Le contrôle doit finir par **`OK`**. Attendu :

- « Ajouts sur des ressources de CINAF » : **aucun** (les règles 400 et 401, le certificat et la règle 5432 existent déjà : `no-op`) ;
- créations, toutes à nous : `module.prod.module.ecs.aws_ecs_task_definition.media`, les rôles `ev-prod-api-task`, `ev-prod-media-task`, `ev-prod-media-execution` et leurs politiques, le secret `eventide/prod/admin-emails`, `module.prod.module.content.aws_s3_bucket_cors_configuration.this[0]` ;
- « à relire » : nos définitions de tâches `api`, `migrate`, `jobs` **remplacées** (nouvelles variables), cycle de vie du bucket de contenu, registraire `ev-prod-task-registrar` et sa politique, rôle `ev-prod-github-deploy`, paramètre `/eventide/prod/deploy/config`, budgets (`terraform_data`).

Vérification rapide des actions et de la règle CORS :

```bash
jq -r '.resource_changes[] | select((.change.actions | inside(["create","no-op","read"])) | not)
  | "\(.change.actions | join(",")) \(.address)"' tfplan.json
jq '.resource_changes[] | select(.type == "aws_s3_bucket_cors_configuration") | .change.after.cors_rule' tfplan.json
#   → allowed_methods ["POST"], allowed_origins ["https://<domaine>", "https://www.<domaine>"]
```

Avec votre accord pour **cet** `apply` : `terraform apply tfplan && rm tfplan tfplan.json`.

> ⚠ `tfplan` et `tfplan.json` contiennent des secrets en clair : ne jamais les partager ; les supprimer après l'apply.

## 5. Désigner les administrateurs (secret `ADMIN_EMAILS`)

Le secret est créé avec la valeur provisoire `A_REMPLACER` : **personne n'est administrateur** tant qu'il n'est pas rempli. Valeur : les adresses des comptes Google autorisés, **séparées par des virgules, sans espace**, en minuscules. Jamais dans git, dans les `tfvars`, dans un ticket ni dans une conversation.

Dans **AWS CloudShell** (us-east-1), sans laisser de fichier :

```bash
read -r -p "Adresses des administrateurs (séparées par des virgules) : " EMAILS
printf '%s' "$EMAILS" | aws secretsmanager put-secret-value --secret-id eventide/prod/admin-emails \
  --secret-string file:///dev/stdin --query VersionId --output text
unset EMAILS
```

Les tâches lisent ce secret **au démarrage** : passer à l'étape 6 (ou, s'il n'y a rien à déployer, `aws ecs update-service --cluster ev-prod --service api --force-new-deployment`). Pour **retirer un administrateur** : même commande sans son adresse, puis forcer un nouveau déploiement du service ; l'accès est coupé quand les nouvelles tâches ont remplacé les anciennes (quelques minutes).

## 6. Déployer

GitHub → *Actions* → **Deploy** → `prod`, migrations cochées. Le workflow enregistre aussi la famille `ev-prod-media` avec la nouvelle image (après les migrations, avant le service). Dans le résumé : ligne « Traitement des médias » avec une révision `ev-prod-media:<n>`.

## 7. Vérifier

- [ ] `https://<domaine>/tableau/` : bouton « Se connecter avec Google », connexion avec un compte de `ADMIN_EMAILS` → tableau de bord ; avec un autre compte → « Accès refusé ».
- [ ] Publier un court paysage de test (vidéo de quelques secondes à quelques Mo) : l'état passe de `envoi` à `traitement` puis `pret`. Dans CloudShell :

  ```bash
  aws ecs list-tasks --cluster ev-prod --family ev-prod-media --desired-status STOPPED --max-items 3
  aws logs tail /ecs/ev-prod/jobs --log-stream-name-prefix media --since 30m --format short
  aws s3 ls "s3://ev-prod-content-466494951409/uploads/" --recursive | tail -3   # la source
  aws s3 ls "s3://ev-prod-content-466494951409/videos/paysages/" | tail -3      # le résultat
  ```

- [ ] Aperçu, publication, puis l'élément apparaît dans l'application (catalogue publié, contrat § 13).
- [ ] CINAF, JobMinutes et Candidature Express répondent comme avant (leurs pages d'accueil).
- [ ] Une semaine après : les sources de `uploads/` de plus de 7 jours ont disparu.

## 8. Dépannage

| Symptôme | Piste |
|---|---|
| Plan : « google_web_client_id doit aussi figurer dans google_oauth_client_ids » | Ajouter l'identifiant à la liste (§ 3) |
| Plan : « Pic de vCPU Fargate … au-delà du budget » ou « Connexions possibles du rôle applicatif … + 1 (tâches media) » | Décisions du § 1 ; ne pas relever un budget sans votre accord |
| `check-plan-additions-only.sh` : `ÉCHEC` | Ne pas appliquer ; transmettre la sortie (chaque ligne nomme la ressource et la règle enfreinte) |
| Bouton Google : « origin_mismatch » ou « The given origin is not allowed » | Origines JavaScript du client OAuth (§ 2, étape 3) : `https://<domaine>` et `https://www.<domaine>` exactement |
| « Accès refusé » pour un administrateur | Adresse absente ou mal écrite dans `ADMIN_EMAILS`, ou service pas redéployé depuis le changement (§ 5) |
| Navigateur : erreur CORS pendant l'envoi | La page n'est pas servie par `https://<domaine>` ou `https://www.<domaine>` ; vérifier `aws s3api get-bucket-cors --bucket ev-prod-content-466494951409` |
| Envoi refusé (`403 AccessDenied`) par S3 | Formulaire expiré (recommencer), fichier de plus de 300 Mo, ou `apply` du § 4 pas fait |
| Le traitement ne démarre pas ; journal de l'API `AccessDenied … ecs:RunTask` ou `Unable to find task definition` | `apply` du § 4 pas fait, ou Deploy du § 6 pas relancé |
| E-mail « Tâche ECS en échec » (`ev-prod-one-off-task-failed`) pour `media` | Journaux `/ecs/ev-prod/jobs`, flux `media/` ; une source illisible doit finir en état `echec` sans alerte |

## 9. Retour arrière

- **Couper l'accès** sans rien supprimer : remettre `A_REMPLACER` dans `eventide/prod/admin-emails` (§ 5), puis forcer un nouveau déploiement du service.
- **Tout retirer** : revenir au code précédent, `terraform plan`, contrôle (`OK` : seules nos ressources du tableau de bord sont supprimées, aucun point de contact touché), relecture, `apply` avec votre accord. Les fichiers déjà publiés restent dans le bucket ; le secret part en période de récupération (30 jours). Le client OAuth se supprime dans Google Cloud.
