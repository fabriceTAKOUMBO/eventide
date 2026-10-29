# Runbook — Premier déploiement d'Eventide (hébergement mutualisé, compte principal, us-east-1)

| | |
|---|---|
| **Quand l'utiliser** | Mise en service du serveur d'Eventide dans le compte AWS principal `466494951409`, à côté de CINAF, JobMinutes et Candidature Express ([ADR](../infra/hebergement-mutualise.md)). |
| **Qui** | Le product owner (administrateur du compte AWS, du dépôt GitHub, de la Play Console et du projet Google Cloud). |
| **Durée** | Phase 1 (sans domaine) : 2 à 3 heures. Phase 2 (domaine) : 1 heure, plus la propagation DNS et la validation du certificat. |
| **Résultat** | Phase 1 : base `eventide` et rôles sur l'instance partagée, image dans ECR, migrations passées, contenu déposé, sauvegarde quotidienne et restauration testée, alertes et budgets actifs, **sans entrée publique**. Phase 2 : `https://api.<domaine>` et `https://<domaine>` servis par ECS Fargate, notifications Google Play reçues. |
| **Règle d'or** | **Aucun `apply` sans (a) le contrôle `check-plan-additions-only.sh` vert sur le plan et (b) la relecture du plan par le product owner** ([encadré](#avant-chaque-apply--contrôle-et-relecture-obligatoires)) : aucune ressource de CINAF, JobMinutes ou Candidature Express modifiée, remplacée, supprimée ni importée ; seuls nos ajouts permis. Un plan qui touche une de leurs ressources est une anomalie : ne pas appliquer, signaler. |
| **Exécution** | **Pas encore exécuté** (28 octobre 2026). Les identifiants de l'infrastructure partagée viennent de Candidature Express (relevés le 9 octobre 2026) : à reconfirmer (§ 4). |

## Sommaire

1. [Prérequis](#1-prérequis)
2. [État Terraform (bootstrap)](#2-état-terraform-bootstrap)
3. [Étiquette de coûts](#3-étiquette-de-coûts)
4. [Configuration de la pile et vérifications en lecture seule](#4-configuration-de-la-pile-et-vérifications-en-lecture-seule)
5. [Phase 1 : plan, relecture, apply (sans domaine)](#5-phase-1--plan-relecture-apply-sans-domaine)
6. [Secrets à déposer](#6-secrets-à-déposer)
7. [Amorçage de la base (une fois)](#7-amorçage-de-la-base-une-fois)
8. [GitHub : sujet OIDC, environnement, variables](#8-github--sujet-oidc-environnement-variables)
9. [Premier déploiement de l'image](#9-premier-déploiement-de-limage)
10. [Contenu (sons et images)](#10-contenu-sons-et-images)
11. [Phase 2 : domaine, entrée publique, Google Play](#11-phase-2--domaine-entrée-publique-google-play)
12. [Sauvegarde et test de restauration](#12-sauvegarde-et-test-de-restauration)
13. [Tests de fumée](#13-tests-de-fumée)
14. [Préproduction (facultative)](#14-préproduction-facultative)
15. [Après la mise en service](#15-après-la-mise-en-service)
16. [Dépannage](#16-dépannage)
17. [Tout retirer](#17-tout-retirer)

---

## Avant chaque `apply` : contrôle et relecture obligatoires

À faire pour **chaque** `apply` de ce runbook (bootstrap, phases 1 et 2, sujet OIDC, préproduction, retrait), sans exception ([règle absolue d'`AGENTS.md`](../../AGENTS.md), [ADR § 11](../infra/hebergement-mutualise.md#11-non-influence-sur-cinaf-jobminutes-et-candidature-express)) :

```bash
terraform plan -out=tfplan                     # retrait : terraform plan -destroy -out=tfplan
terraform show -json tfplan > tfplan.json
bash "$(git rev-parse --show-toplevel)/.github/scripts/check-plan-additions-only.sh" tfplan.json
#   retrait : … check-plan-additions-only.sh --destroy tfplan.json
```

1. **(a) Le contrôle doit finir par `OK`** (code de sortie 0). Il refuse : toute action autre qu'un ajout sur une ressource qui n'est pas à Eventide ; tout type de ressource partagée (ALB, écouteur, RDS, VPC, sous-réseaux, NAT, routes, points de terminaison VPC, DNS privé, WAF…) ou de réglage du compte ; tout objet posé sur une ressource partagée hors des quatre points de contact de l'ADR (règles d'écouteur 400-409 / 420-429 limitées à nos noms d'hôte, certificat, règle 5432 depuis notre seul groupe) ; tout import d'un tel objet ; une étiquette `Project` autre que `eventide`, un nom sans nos préfixes, un filtre de métrique sur un groupe de journaux qui n'est pas à nous, une action d'alarme autre que SNS. `ÉCHEC` : **ne pas appliquer**, garder la sortie et la transmettre.
2. **(b) Le product owner relit** la sortie du contrôle (points de contact créés, ressources d'Eventide modifiées ou remplacées) et le plan lui-même, puis donne son accord pour **cet** `apply`. Le contrôle ne remplace pas la relecture.
3. `terraform apply tfplan`, puis `rm tfplan tfplan.json`.

> ⚠ `tfplan` et `tfplan.json` contiennent des secrets en clair (mots de passe des rôles, clé Django, clé privée de signature : `terraform show -json` ne les masque pas). Ne jamais les partager ni les déposer dans le dépôt ; les supprimer après l'`apply`.

## 1. Prérequis

- **Session AWS** : IAM Identity Center, jeu d'autorisations **AdministratorAccess** sur le compte `466494951409`. Nos clés KMS et le bucket de l'état n'autorisent le déchiffrement et la lecture qu'à ce jeu d'autorisations et à nos rôles : lancer **toutes** les commandes Terraform (bootstrap compris) avec cette session. Profil `principal` décrit par Candidature Express (portail Identity Center en `eu-north-1`, région par défaut `us-east-1`) :

  ```bash
  aws sso login --profile principal
  export AWS_PROFILE=principal AWS_REGION=us-east-1
  aws sts get-caller-identity --query Account --output text   # 466494951409
  ```

- **Outils** : Terraform 1.16.x (≥ 1.10), AWS CLI v2, `jq`, `gh`. Commandes écrites pour bash (sous Git Bash, préfixer par `MSYS_NO_PATHCONV=1` toute commande dont un argument commence par `/`). Pour les étapes 6 et 7, **AWS CloudShell** (us-east-1) évite d'écrire quoi que ce soit sur le poste.
- **Décisions prises** : destinataires des alertes et des budgets, préproduction ou non (§ 14), nom de domaine (phase 2 seulement).
- **Côté Google** (peut se faire en parallèle, nécessaire avant l'ouverture) :
  - application créée dans la Play Console (nom du paquet, empreinte SHA-256 du certificat de signature d'application de Play) ;
  - projet Google Cloud lié à l'application dans la Play Console (Play Integrity) ; API **Google Play Android Developer** et **Play Integrity** activées ;
  - compte de service de ce projet, invité dans la Play Console (*Utilisateurs et autorisations*) avec les droits de consultation des données financières et de gestion des commandes et abonnements ; clé JSON créée (elle sera déposée au § 6, jamais ailleurs) ;
  - identifiant client OAuth « Application Web » utilisé par l'application comme `serverClientId` pour la connexion Google (c'est l'audience du jeton d'identité vérifié par l'API) ;
- Produits Google Play à créer avec ces identifiants (ceux du code) : abonnement `eventide_premium` (offres de base `monthly`, `annual`), achat unique `eventide_lifetime` (plus de pack de crédits : assistant vocal retiré le 29 octobre 2026).

## 2. État Terraform (bootstrap)

Une fois pour ce compte. Crée le bucket `eventide-tfstate-466494951409` (versionné, accès public bloqué, TLS obligatoire, chiffré par la clé `alias/eventide-tfstate`) ; verrouillage natif S3 (`use_lockfile`), sans DynamoDB. La pile garde son propre état en local.

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars      # compte 466494951409, us-east-1
terraform init
terraform plan -out=tfplan
```

Contrôle obligatoire ([encadré](#avant-chaque-apply--contrôle-et-relecture-obligatoires)) : `terraform show -json tfplan > tfplan.json && bash ../../../.github/scripts/check-plan-additions-only.sh tfplan.json` → `OK`. Relecture par le product owner : uniquement des **ajouts** (bucket et ses réglages, clé KMS et son alias), **aucun avertissement** `check "terraform_session_can_use_state"` (sinon la session ne pourrait pas utiliser l'état : ne pas appliquer, se reconnecter avec AdministratorAccess). Puis, avec son accord :

```bash
terraform apply tfplan && rm tfplan tfplan.json
terraform output -raw backend_hcl > ../envs/shared-prod/backend.hcl
```

`terraform.tfvars`, `backend.hcl` et l'état local (`terraform.tfstate`) sont ignorés par git ; ranger l'état local dans le coffre de l'équipe.

**Fichiers de verrouillage des fournisseurs** : `.terraform.lock.hcl` n'est pas encore dans le dépôt (le registre Terraform n'était pas joignable quand le code a été écrit). Au premier `init`, le générer pour toutes les plateformes utilisées, le relire et le proposer par pull request :

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64
```

(à faire dans `bootstrap` et dans `envs/shared-prod`).

## 3. Étiquette de coûts

1. Console **Billing and Cost Management → Cost allocation tags** : la clé **`Project`** est déjà active (utilisée par les autres produits) ; **vérifier seulement**. Activer une autre clé (par exemple `Environment`) est un réglage de tout le compte (règle 3 d'`AGENTS.md`) : ne le faire que sur décision explicite du product owner, après accord des autres produits. Sans elle, la production et la préproduction se distinguent par leurs budgets (`ev-prod-content-mensuel`) et par les noms de ressources.
2. Le budget `eventide-mensuel` (`monthly_budget_usd`, 60 USD par défaut : alertes à 50, 80 et 100 % du réel et 100 % de la prévision), le budget du contenu `ev-prod-content-mensuel` (`content_budget_usd`, 30 USD) et le moniteur d'anomalies (`anomaly_threshold_usd`, 10 USD) sont créés par Terraform et filtrés sur `Project = eventide`. Ils ne voient rien tant que les premières ressources ne sont pas étiquetées : vérifier une semaine après.
3. Si la création du moniteur d'anomalies est refusée, mettre `cost_guardrails_enabled = false`, appliquer, puis le repasser à `true`.

## 4. Configuration de la pile et vérifications en lecture seule

```bash
cd infra/terraform/envs/shared-prod
cp terraform.tfvars.example terraform.tfvars
# Renseigner : alert_emails, budget_emails, github_subject_repository (§ 8), et si connus :
# play_package_name, android_cert_fingerprints, google_oauth_client_ids,
# rtdn_service_account_email, legal_publisher_name, legal_contact_email.
# Laisser domain_name = "" pour la phase 1.
terraform init -backend-config=backend.hcl
terraform test     # fournisseurs simulés : aucun appel AWS
```

**Reconfirmer les identifiants de CINAF** (métadonnées seulement, aucune modification, aucun contenu lu) :

```bash
ALB=$(aws elbv2 describe-load-balancers --names cinaf-streaming-prod-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" \
  --query 'LoadBalancers[0].[VpcId,Scheme,SecurityGroups]'                  # vpc-0fbfe87b34e2b3903, internet-facing
LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB" \
  --query 'Listeners[?Port==`443`].ListenerArn' --output text)
aws elbv2 describe-rules --listener-arn "$LISTENER" --query 'Rules[].Priority' --output text
#   → 400 à 409 et 420 à 429 doivent être LIBRES (sinon choisir un autre listener_priority_base)
aws ec2 describe-subnets --subnet-ids subnet-03bb1c6197c29a369 subnet-0fcd9f10a65ed1a16 \
  --query 'Subnets[].[SubnetId,VpcId,AvailabilityZone,AvailableIpAddressCount]' --output table
aws rds describe-db-instances --db-instance-identifier cinaf-streaming-prod-postgres \
  --query 'DBInstances[0].[EngineVersion,MultiAZ,VpcSecurityGroups[].VpcSecurityGroupId]'
#   → 16.x et sg-070b4372d5a95ad2d
aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=cinaf-streaming-prod-postgres \
  --start-time "$(date -u -d '-14 days' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 86400 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[].Maximum' --output text
#   → marge : pic observé + 14 (Eventide) bien en dessous de max_connections de l'instance

# Quota Fargate commun à tout le compte (pic d'Eventide : 1,75 vCPU en production, plafonné à 2
# par Terraform ; préproduction en Spot : 1,25) : valeur du quota et marge restante.
aws service-quotas get-service-quota --service-code fargate --quota-code L-3032A538 \
  --query 'Quota.[QuotaName,Value]' --output text     # Fargate On-Demand vCPU resource count
aws service-quotas get-service-quota --service-code fargate --quota-code L-36FBB829 \
  --query 'Quota.[QuotaName,Value]' --output text     # Fargate Spot vCPU resource count
# Les images de nos tâches passent-elles par un point de terminaison S3 de CINAF (gratuit) ou par
# la NAT (0,045 USD/Go facturés sur la NAT de CINAF) ? Métadonnées seulement.
aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=vpc-0fbfe87b34e2b3903 \
  --query 'VpcEndpoints[].[ServiceName,VpcEndpointType]' --output table
```

(Si un code de quota ne répond pas, chercher « Fargate » dans la console Service Quotas : lecture seule.)

À voir **avec l'équipe CINAF** (aucune modification de notre part) :

- [ ] Le Terraform de CINAF décrit-il le groupe de sécurité de la base et l'écouteur 443 avec des règles **autonomes** ? Sinon son prochain `apply` supprimerait nos ajouts (et ceux des autres invités).
- [ ] Mot de passe maître disponible pour l'étape 7 : seul le product owner le lit (secret de CINAF), pour le copier dans le secret temporaire ; ni Terraform, ni nos tâches, ni les agents ne le lisent.
- [ ] Marge de connexions confirmée (budget d'Eventide : 14).
- [ ] Coûts portés par les ressources de CINAF signalés à l'équipe CINAF : données traitées par la NAT (images de nos tâches : ≈ 0,5 à 4 USD/mois selon la présence d'un point de terminaison S3) et unités de capacité de l'ALB (< 1 USD/mois au lancement) ([ADR § 11](../infra/hebergement-mutualise.md#11-non-influence-sur-cinaf-jobminutes-et-candidature-express)).

## 5. Phase 1 : plan, relecture, apply (sans domaine)

```bash
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json
bash ../../../.github/scripts/check-plan-additions-only.sh tfplan.json
```

Contrôle obligatoire : la sortie finit par `OK` et la section « Ajouts sur des ressources de CINAF » ne contient **qu'une** ligne, `module.prod.aws_vpc_security_group_ingress_rule.shared_postgres : create (tcp 5432 depuis notre groupe)`. Sinon : ne pas appliquer.

Relecture obligatoire par le product owner :

- [ ] Dernière ligne : `Plan: N to add, 0 to change, 0 to destroy.` (N à noter ici au premier plan).
- [ ] Rien d'autre que des créations :

  ```bash
  terraform show -json tfplan | jq -r '.resource_changes[] | .change.actions | join(",")' | sort | uniq -c
  #   → seulement « create » (et « no-op » / « read »)
  ```

- [ ] Ajouts sur des ressources partagées, et seulement ceux-là :

  ```bash
  terraform show -json tfplan | jq -r '.resource_changes[]
    | select(.type == "aws_lb_listener_rule" or .type == "aws_lb_listener_certificate" or (.address | test("shared_postgres")))
    | "\(.change.actions | join(",")) \(.address) \(.change.after.priority // "")"'
  ```

  Attendu en phase 1 : **une seule ligne**, `create module.prod.aws_vpc_security_group_ingress_rule.shared_postgres` (aucune règle d'écouteur, aucun certificat : pas de domaine).
- [ ] Aucun avertissement `check "terraform_session_can_decrypt"`.
- [ ] Sortie `shared_infrastructure` du plan : ALB `cinaf-streaming-prod-alb`, PostgreSQL `16.x`, écouteur et fournisseur OIDC trouvés ; `route53_zone = null`.

> ⚠ Le fichier `tfplan` contient des secrets générés en clair (mots de passe des rôles, clé Django, clé privée de signature) : ne jamais le partager ; le supprimer après l'apply.

Avec l'accord du product owner :

```bash
terraform apply tfplan && rm tfplan tfplan.json
terraform output -json prod > /tmp/ev-prod.json   # aucun secret ; à supprimer à la fin
```

Ensuite :

- Confirmer l'abonnement : chaque adresse d'alerte reçoit un e-mail *AWS Notification - Subscription Confirmation* (sujet `ev-prod-alerts`) : cliquer sur le lien.
- Normal à ce stade : les tâches planifiées (`purge-expired`, `finalize-purchases`) échouent tant que l'image n'est pas déployée (image `bootstrap` absente), et la sauvegarde échoue tant que la base n'est pas amorcée : e-mails « tâche en erreur ». Enchaîner les §§ 6, 7 et 9 le même jour.

## 6. Secrets à déposer

Un secret est créé avec la valeur provisoire `A_REMPLACER` (l'API répond alors `503` et l'alarme `ev-prod-google-not-configured` se déclenche) : `eventide/prod/google-play-service-account` (sortie `secrets_to_fill`). Dans CloudShell, sans laisser de fichier :

```bash
# Clé JSON du compte de service Google Play : téléverser le fichier dans CloudShell, puis
aws secretsmanager put-secret-value --secret-id eventide/prod/google-play-service-account \
  --secret-string file://cle-compte-de-service.json --query VersionId --output text
shred -u cle-compte-de-service.json
```

Les tâches lisent les secrets **au démarrage** : relancer le déploiement (§ 9) ou forcer un nouveau déploiement du service après un changement. Les autres secrets (`django-secret-key`, `db-app`, `db-migrator`, `db-backup`, `cloudfront-private-key`) sont générés par Terraform : ne pas les modifier à la main.

## 7. Amorçage de la base (une fois)

La tâche `ev-prod-db-bootstrap` crée, avec le compte maître de l'instance partagée, la base `eventide`, la base vide `eventide_restore`, les rôles `ev_app`, `ev_migrator`, `ev_backup`, leurs limites de connexions (10, 2, 2 ; base 14) et leurs délais, puis les droits ([`bootstrap.sql`](../../infra/terraform/modules/db_tools/files/bootstrap.sql), [`grants.sql`](../../infra/terraform/modules/db_tools/files/grants.sql)). Le mot de passe maître passe par un **secret temporaire** ; les mots de passe de nos rôles partent sous forme de vérificateurs SCRAM.

Dans **AWS CloudShell** (us-east-1), avec les valeurs de `terraform output -json prod` (aucun secret) :

```bash
CLUSTER=ev-prod
FAMILY=ev-prod-db-bootstrap
SECRET_NAME=eventide/prod/bootstrap/rds-master-password
SUBNETS=subnet-03bb1c6197c29a369,subnet-0fcd9f10a65ed1a16
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=ev-prod-api \
  --query 'SecurityGroups[0].GroupId' --output text)

# 1. Secret temporaire : mot de passe saisi sans écho, passé par l'entrée standard.
read -rs -p "Mot de passe maître de cinaf-streaming-prod-postgres : " PGMASTER; echo
# Chiffré par NOTRE clé (alias/ev-prod) : elle refuse le déchiffrement aux rôles des autres
# produits du compte ; la clé par défaut aws/secretsmanager le laisserait lisible par tout rôle
# du compte ayant secretsmanager:GetSecretValue pendant sa courte vie.
printf '%s' "$PGMASTER" | aws secretsmanager create-secret --name "$SECRET_NAME" \
  --description "TEMPORAIRE - amorcage Eventide - a supprimer" --kms-key-id alias/ev-prod \
  --secret-string file:///dev/stdin --query Name --output text
unset PGMASTER

# 2. Tâche d'amorçage.
TASK=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY" \
  --capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
  --started-by runbook-bootstrap --query 'tasks[0].taskArn' --output text)
aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK"
aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
  --query 'tasks[0].containers[].[name,exitCode,reason]' --output table

# 3. Supprimer le secret temporaire TOUT DE SUITE (même en cas d'échec).
aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery

# 4. Journaux (aucun secret n'y figure).
aws logs tail /ecs/ev-prod/jobs --log-stream-name-prefix db-bootstrap --since 30m --format short
```

Attendu : conteneurs `init`, `scram` et `bootstrap` en code `0` ; dans les journaux `db_scram_verifiers_ready`, `db_bootstrap_started` puis `db_bootstrap_done`, les trois rôles avec `connexion = t` et `superutilisateur = f`, les limites `10 / 2 / 2`, leurs réglages (`statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`, `work_mem`, `maintenance_work_mem`, `idle_session_timeout`, `max_parallel_workers_per_gather=0`, `max_parallel_maintenance_workers=0`, et `temp_file_limit` si le compte maître a le droit de le poser), la base `eventide` avec la limite `14` et des droits sans entrée pour PUBLIC.

- `db_bootstrap_temp_file_limit_skipped` : le compte maître de l'instance n'a pas le droit `SET` sur `temp_file_limit` (paramètre réservé au superutilisateur) ; tous les autres plafonds sont posés. Rien à faire de notre côté (ne pas demander de droit supplémentaire sans décision du product owner) ; noter le constat dans le journal.

- En cas d'échec après l'appartenance temporaire du compte maître à `ev_migrator`, la tâche la retire elle-même (`db_bootstrap_cleanup_done`). Si le journal montre `db_bootstrap_cleanup_failed`, lancer la commande `REVOKE` indiquée, connecté avec le compte maître, avant toute autre action.
- `role existant sans le marqueur eventide` : un rôle `ev_*` du même nom existe et n'est pas à nous ; rien n'a été modifié. Ne pas le « récupérer » : changer `db_roles` ou voir avec CINAF.
- `base existante dont le proprietaire n est pas notre role de migration` : une base `eventide*` existe et n'est pas à nous ; rien n'a été modifié. Même conduite.
- Le script est idempotent : le relancer de la même façon après une rotation des mots de passe des rôles.
- **Variante console** pour le secret temporaire : Secrets Manager, *Stocker un nouveau secret*, *Autre type de secret*, *Texte brut* : le mot de passe seul ; nom `eventide/prod/bootstrap/rds-master-password` ; puis lancer la tâche et supprimer le secret par la commande du point 3 (la console impose 7 jours d'attente).

## 8. GitHub : sujet OIDC, environnement, variables

1. **Sujet OIDC** du dépôt (une fois, sans effet sur les autres dépôts qui partagent le fournisseur OIDC) :

   ```bash
   gh api -X PUT repos/fabriceTAKOUMBO/eventide/actions/oidc/customization/sub \
     -F use_default=false -f 'include_claim_keys[]=repo' -f 'include_claim_keys[]=context' -f 'include_claim_keys[]=ref'
   gh api repos/fabriceTAKOUMBO/eventide/actions/oidc/customization/sub
   ```

   Garder le format **immuable**. Le préfixe `sub_claim_prefix` vaut `repo:fabriceTAKOUMBO@<id du propriétaire>/eventide@<id du dépôt>` : reporter la partie après `repo:` dans `github_subject_repository` (`terraform.tfvars`), puis plan (seule la politique d'approbation du rôle `ev-prod-github-deploy` change), contrôle `check-plan-additions-only.sh` (une ligne « à relire » : `update` du rôle), relecture et `apply`. Tant que la valeur provisoire de l'exemple est en place, GitHub ne peut pas prendre le rôle (`Not authorized to perform sts:AssumeRoleWithWebIdentity`).
2. **Environnement GitHub `prod`** (branche `main` seulement, relecteur si le plan GitHub le permet), puis ses variables :

   ```bash
   cd infra/terraform/envs/shared-prod
   gh variable set AWS_REGION --env prod --body us-east-1 -R fabriceTAKOUMBO/eventide
   gh variable set AWS_DEPLOY_ROLE_ARN --env prod -R fabriceTAKOUMBO/eventide \
     --body "$(terraform output -json prod | jq -r .github_deploy_role_arn)"
   MSYS_NO_PATHCONV=1 gh variable set DEPLOY_CONFIG_PARAMETER --env prod -R fabriceTAKOUMBO/eventide \
     --body "$(terraform output -json prod | jq -r .deploy_config_parameter)"   # /eventide/prod/deploy/config
   gh variable list --env prod -R fabriceTAKOUMBO/eventide
   ```

3. Runner : images **ARM64** construites sur `ubuntu-24.04-arm` ; variable de dépôt facultative `DEPLOY_RUNNER` pour un autre runner (émulation QEMU, plus lente).

## 9. Premier déploiement de l'image

GitHub → *Actions* → **Deploy** → *Run workflow* : branche `main`, environnement `prod`, `image_tag` vide, migrations cochées.

Le workflow lit sa configuration dans SSM (`/eventide/prod/deploy/config`), construit l'image `linux/arm64`, la pousse dans `ev-prod-api`, vérifie le scan ECR (toute vulnérabilité `CRITICAL` absente de `.github/accepted-cves.txt` bloque la production), fait enregistrer les révisions `api`, `migrate` et `jobs` par **notre registraire** (fonction Lambda `ev-prod-task-registrar` : modèle écrit par Terraform, seule l'image change ; le rôle de déploiement ne lit ni n'écrit aucune définition de tâche lui-même), lance les migrations en tâche ponctuelle (rôle `ev_migrator`), met à jour le service `api` **s'il existe** (phase 2 seulement ; en phase 1 un avis « Service api absent » est normal), enregistre le tag dans SSM et lance les tests de fumée (phase 2).

Après ce premier déploiement, un `terraform plan` complet propose de **remplacer** nos définitions de tâches (`api`, `migrate`, `jobs` : Terraform suit le tag déployé, lu dans SSM ; chaque remplacement compte un `destroy`) : attendu, sans effet sur les autres produits. Pour un changement limité, cibler (`-target`) les ressources concernées.

## 10. Contenu (sons et images)

Le contenu est servi par **notre** distribution CloudFront, depuis le bucket privé `ev-prod-content-466494951409` (sortie `content.bucket`) ; l'API délivre des adresses signées d'une heure (`POST /v1/content/urls`). Les clés suivent le catalogue (`backend/eventide/catalog.json`, copie exacte de `app/assets/catalog.json`) :

| Type | Clé | Type MIME |
|---|---|---|
| Son | `audio/sons/<id>.ogg` | `audio/ogg` |
| Musique | `audio/musiques/<id>.ogg` | `audio/ogg` |
| Paysage | `images/paysages/<id>.jpg` | `image/jpeg` |
| Vidéo de paysage | `videos/paysages/<id>.mp4` | `video/mp4` |

```bash
BUCKET=$(jq -r .content.bucket /tmp/ev-prod.json)
aws s3 sync ./contenu/audio "s3://$BUCKET/audio" --exclude '*' --include '*.ogg' \
  --content-type audio/ogg --cache-control 'public, max-age=604800'
aws s3 sync ./contenu/images "s3://$BUCKET/images" --exclude '*' --include '*.jpg' \
  --content-type image/jpeg --cache-control 'public, max-age=604800'
aws s3 sync ./contenu/videos "s3://$BUCKET/videos" --exclude '*' --include '*.mp4' \
  --content-type video/mp4 --cache-control 'public, max-age=604800'
```

Un fichier remplacé garde le même nom : invalider le cache (`aws cloudfront create-invalidation --distribution-id "$(jq -r .content.distribution_id /tmp/ev-prod.json)" --paths '/audio/sons/<id>.ogg'`) ou, mieux, changer d'identifiant dans le catalogue. Vérification : une adresse non signée doit être refusée (`403`) ; une adresse signée par l'API répond `200` (phase 2, § 13).

## 11. Phase 2 : domaine, entrée publique, Google Play

Quand le nom est validé et le domaine acheté (la zone Route 53 publique est créée à l'achat, dans ce compte) :

1. **Étiqueter NOTRE zone** Route 53 (créée à l'achat, dans ce compte où vivent aussi les zones des autres produits) : le plan échoue tant que la zone de `domain_name` ne porte pas `Project = eventide`, pour ne jamais écrire dans la zone d'un autre produit.

   ```bash
   ZONE=$(aws route53 list-hosted-zones-by-name --dns-name "<domaine>." --max-items 1 \
     --query 'HostedZones[0].[Id,Name]' --output text); echo "$ZONE"   # vérifier le nom !
   aws route53 change-tags-for-resource --resource-type hostedzone \
     --resource-id "$(cut -f1 <<< "$ZONE" | sed 's#/hostedzone/##')" --add-tags Key=Project,Value=eventide
   ```

   `domain_name` ne peut pas être un domaine (ni un sous-domaine) de CINAF, JobMinutes ou Candidature Express (`cinaf.tv`, `jobminutes.com`, `candidatureexpress.com` : refus de Terraform).
2. `terraform.tfvars` : `domain_name = "<domaine>"` (et `content_custom_domain = true` pour `cdn.<domaine>`, facultatif). Renseigner aussi `play_package_name`, `android_cert_fingerprints`, `google_oauth_client_ids`, `rtdn_service_account_email`, `legal_publisher_name` et `legal_contact_email` s'ils ne le sont pas.
3. `terraform plan -out=tfplan`, puis le contrôle obligatoire (`terraform show -json tfplan > tfplan.json && bash ../../../.github/scripts/check-plan-additions-only.sh tfplan.json`) : `OK`, avec dans « Ajouts sur des ressources de CINAF » exactement les règles **400** (`api.<domaine>`) et **401** (`<domaine>`, `www.<domaine>`) et le certificat ; dans « à relire », nos définitions de tâches remplacées et notre paramètre SSM. Puis relecture par le product owner :
   - [ ] les seules modifications et suppressions portent sur **nos** ressources : définitions de tâches `ev-prod-*` **remplacées** (nouvelles variables d'environnement : hôtes, URL publiques, audience RTDN ; chaque remplacement compte un `destroy`, qui désenregistre l'ancienne révision), paramètre SSM `/eventide/prod/deploy/config`, éventuellement la distribution de contenu (alias `cdn.`) ; **aucune** sur une ressource partagée :

     ```bash
     terraform show -json tfplan | jq -r '.resource_changes[]
       | select((.change.actions | inside(["create","no-op","read"])) | not)
       | "\(.change.actions | join(",")) \(.address)"'
     ```

   - [ ] le filtre du § 5 affiche maintenant `no-op` pour `shared_postgres` (créée en phase 1) et **3 `create`** : règles **400** (`api`) et **401** (`web`), **1** `aws_lb_listener_certificate` ; rien d'autre ;
   - [ ] sortie `shared_infrastructure.route53_zone` = `<domaine>.`.
4. Avec l'accord du product owner : `terraform apply tfplan && rm tfplan tfplan.json`. Le certificat est validé automatiquement par DNS (zone dans ce compte) ; le service `api` démarre avec la dernière image déployée.
5. Relancer **Deploy** (`prod`, migrations cochées) : cette fois le service est mis à jour et les tests de fumée tournent.
6. **Notifications Google Play (RTDN)** : dans Google Cloud, sujet Pub/Sub (par ex. `eventide-play`) ; donner le rôle *Pub/Sub Publisher* sur ce sujet à `google-play-developer-notifications@system.gserviceaccount.com` ; abonnement **push** vers `https://api.<domaine>/v1/play/rtdn`, **authentification activée** avec le compte de service `rtdn_service_account_email` et l'audience `https://api.<domaine>/v1/play/rtdn` (valeur de `RTDN_AUDIENCE`). Play Console → *Monétisation* → *Notifications en temps réel pour les développeurs* : nom complet du sujet, puis *Envoyer une notification de test* : l'API répond `204` (journal `/ecs/ev-prod/api`). Étapes à vérifier dans la documentation Google au moment de le faire (non testées).
7. Associer le site à l'application (liens `https://<domaine>/m/<code>`) : `https://<domaine>/.well-known/assetlinks.json` répond dès que `play_package_name` et `android_cert_fingerprints` sont renseignés (sinon `404`).

## 12. Sauvegarde et test de restauration

La sauvegarde quotidienne (`ev-prod-db-backup`, 03 h 40 heure de Bruxelles) peut être lancée tout de suite après l'amorçage, puis le test de restauration (restaure la plus récente dans `eventide_restore`, compare tables et lignes, puis vide la copie) :

```bash
CLUSTER=ev-prod
SUBNETS=subnet-03bb1c6197c29a369,subnet-0fcd9f10a65ed1a16
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=ev-prod-api --query 'SecurityGroups[0].GroupId' --output text)
for FAMILY in ev-prod-db-backup ev-prod-db-restore-test; do
  TASK=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY" \
    --capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
    --started-by runbook-restore --query 'tasks[0].taskArn' --output text)
  aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$TASK"
  aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" --query 'tasks[0].containers[].[name,exitCode]' --output table
done
aws logs tail /ecs/ev-prod/jobs --log-stream-name-prefix db- --since 30m --format short
```

Attendu : `db_dump_done`, `db_backup_uploaded`, `db_restore_download_done`, `db_restore_test_done` ; tous les conteneurs en code `0`. Noter la date, le nombre de tables et la durée.

**Restauration réelle (incident uniquement)** : arrêter le service `api` (`desired-count 0`) et désactiver les planifications du groupe `ev-prod`, puis lancer `ev-prod-db-restore-test` avec les surcharges `EV_RESTORE_DB_NAME=eventide`, `KEEP_RESTORED=true`, `RESTORE_WITH_PRIVILEGES=true` (et `BACKUP_KEY` pour une sauvegarde précise) sur le conteneur `restore` (et `BACKUP_KEY` sur `download`) ; contrôler, puis rétablir le service et les planifications.

## 13. Tests de fumée

Automatiques (fin du workflow, phase 2) : `/v1/health` → 200, `/v1/health/ready` → 200, `/v1/entitlements` sans jeton → 401, `/confidentialite` → 200, `/s` → 200.

Manuels :

- [ ] `curl -sI https://api.<domaine>/v1/health` : `strict-transport-security` présent ; `curl -sv --tls-max 1.1 https://api.<domaine>/v1/health` échoue (TLS 1.2 minimum, politique de l'écouteur partagé).
- [ ] CINAF, JobMinutes et Candidature Express répondent comme avant (leurs pages d'accueil) : nos règles ne les concernent pas.
- [ ] Application de test (piste interne de la Play Console) : création d'installation (`201`), droits (`GET /v1/entitlements`), adresses signées puis lecture d'un son, partage (`https://<domaine>/m/<code>`).
- [ ] Achat de test (testeur de licence) : `POST /v1/purchases` → `200`, achat acquitté (plus de remboursement automatique après 3 jours), notification RTDN reçue.
- [ ] Journaux `/ecs/ev-prod/api` : JSON, aucun jeton.
- [ ] Alerte de test : `aws cloudwatch set-alarm-state --alarm-name ev-prod-api-5xx --state-value ALARM --state-reason test` → e-mail reçu (prouve que CloudWatch peut publier dans le sujet chiffré par notre clé).
- [ ] Charge sur la base partagée (Performance Insights de l'instance, dimension « Bases de données ») : `eventide` reste marginale.

## 14. Préproduction (facultative)

Désactivée par défaut ([coûts](couts-estimes.md)). Pour l'activer :

1. `preprod_enabled = true`, `terraform plan -out=tfplan`, contrôle `check-plan-additions-only.sh` (`OK` ; ajouts sur les ressources de CINAF : règle 5432 de `module.preprod[0]` et, avec un domaine, règles 420 et 421 et le certificat), relecture, `apply` avec l'accord du product owner.
2. Amorçage de sa base : § 7 avec `CLUSTER=ev-preprod`, `FAMILY=ev-preprod-db-bootstrap`, `SECRET_NAME=eventide/preprod/bootstrap/rds-master-password`, groupe `ev-preprod-api`, clé `--kms-key-id alias/ev-preprod`.
3. Secrets : § 6 avec `eventide/preprod/*`.
4. GitHub : environnement `preprod`, variables `AWS_REGION=us-east-1`, `AWS_DEPLOY_ROLE_ARN` et `DEPLOY_CONFIG_PARAMETER` (sortie `preprod`).

Le service `api` de préproduction tourne de 8 h à 20 h les jours ouvrés (heure de Bruxelles), en Fargate Spot, et s'arrête sinon.

## 15. Après la mise en service

- [ ] Une semaine après : le budget `eventide-mensuel` affiche des dépenses (étiquette active) ; comparer à l'[estimation](couts-estimes.md).
- [ ] Politique de confidentialité (`/confidentialite`) relue par le product owner : hébergement aux États-Unis, durées de conservation, éditeur et contact renseignés (`legal_publisher_name`, `legal_contact_email`).
- [ ] Ranger l'état local du `bootstrap` dans le coffre de l'équipe ; supprimer `/tmp/ev-prod.json`.
- [ ] Recommandé pour toute l'organisation : CloudTrail et GuardDuty.

## 16. Dépannage

| Symptôme | Piste |
|---|---|
| Plan : `precondition` sur `shared_infrastructure_checks` | Un identifiant de `terraform.tfvars` ne correspond plus (CINAF a changé son infrastructure) : ne pas forcer, comprendre d'abord |
| Plan : « Connexions possibles du rôle applicatif … au-delà de sa limite » | `api.max`, `workers` ou `db_pool_max` relevés dans `envs/shared-prod/main.tf` : réduire, ou relever les limites après accord sur la marge de l'instance (puis relancer l'amorçage, § 7) |
| Plan : précondition X-Forwarded-For | L'ALB partagé ne traite plus l'en-tête en mode `append` sans port client : nos limites par IP seraient fausses. Ne pas appliquer ; voir avec CINAF |
| Plan : moins de 30 adresses IP libres | Sous-réseau « application » presque plein : voir avec CINAF |
| Plan : précondition « plus en PostgreSQL 16 » | Mettre à jour l'image et la version de `db_tools` avant tout `apply` |
| Plan : avertissement `check "terraform_session_can_decrypt"` ou `"terraform_session_can_use_state"` | Session qui n'est pas AdministratorAccess : `aws sso login --profile principal`, vérifier `AWS_PROFILE`, relancer |
| `check-plan-additions-only.sh` : `ÉCHEC` | Ne pas appliquer. Chaque ligne nomme la ressource et la règle enfreinte ; transmettre la sortie. Une ressource partagée dans le plan (type interdit, adresse hors liste) est un bogue bloquant (règle 1) |
| Plan : « La zone Route 53 de domain_name ne porte pas l'étiquette Project = eventide » | Zone pas encore étiquetée (§ 11, étape 1), ou `domain_name` désigne la zone d'un autre produit : vérifier le nom avant d'étiqueter quoi que ce soit |
| Plan : « Pic de vCPU Fargate de l'environnement … au-delà du budget » | `api.max`, `api.cpu` ou `deployment_maximum_percent` relevés : le quota Fargate est commun au compte ; réduire, ou relever `fargate_vcpu_budget` après lecture du quota (§ 4) et accord du product owner |
| Plan : « Règle d'écouteur partagé : un nom d'hôte … n'est ni … ni l'un de ses sous-domaines » | Un nom d'hôte de nos règles sort de notre domaine : corriger ; jamais de joker ni de nom d'un autre produit |
| Deploy : `Le registraire a refusé …` ou `Révision inattendue` | Famille ou tag invalides, ou configuration SSM incohérente : relancer après un `apply` de la pile ; ne jamais redonner `ecs:RegisterTaskDefinition` ou `ecs:DescribeTaskDefinition` au rôle de déploiement |
| Apply : `PriorityInUse` sur une règle d'écouteur | Une autre application a pris une priorité de notre plage : choisir un autre `listener_priority_base` (validation Terraform à adapter) |
| Amorçage : `password authentication failed` pour le compte maître | Mauvais mot de passe : supprimer le secret temporaire, le recréer, relancer |
| Amorçage : `rds_ca_checksum` | Nouveau bundle d'autorités RDS : vérifier le fichier, mettre à jour l'empreinte (`db_tools` et `backend/Dockerfile`) |
| Deploy : `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `github_subject_repository` encore provisoire ou faux (§ 8), ou job hors de `main` / de l'environnement `prod` |
| Deploy : scan ECR bloquant (`CRITICAL`) | Documenter la vulnérabilité ; si le product owner l'accepte, l'ajouter à `.github/accepted-cves.txt` par pull request (identifiant, image, date, expiration, raison) |
| Migration : `password authentication failed for user "ev_migrator"` | § 7 non fait, ou à refaire après une rotation |
| Migration : `canceling statement due to lock timeout` | Une migration attend un verrou plus de 10 s : relancer hors pointe |
| API : `too many connections for role "ev_app"` | Budget atteint : tâches ponctuelles en cours ? Ne pas relever la limite sans relever le budget |
| API : `503 integrity_unavailable` ou `play_unavailable`, alarme `ev-prod-google-not-configured` | Secret `google-play-service-account` encore à `A_REMPLACER` ou JSON invalide (§ 6), puis redéployer |
| Alarme `ev-prod-google-credentials` | Le compte de service n'a plus les droits dans la Play Console, ou sa clé est révoquée |
| Alarme `ev-prod-rtdn-rejected` | Audience ou compte de service de l'abonnement push différents de `RTDN_AUDIENCE` / `rtdn_service_account_email` |
| Alarme `ev-prod-purchase-finalization-failed` | Achats non acquittés : Google les rembourse après 3 jours. `finalize-purchases` réessaie chaque heure ; regarder `/ecs/ev-prod/jobs` |
| Alarme `ev-prod-db-backup-missing` | Journaux `/ecs/ev-prod/jobs`, flux `db-backup/*` ; relancer la tâche à la main (§ 12) |
| `403` sur les adresses de contenu | Clé absente du bucket, mauvais type MIME, ou clé de signature changée sans redéploiement de l'API |

## 17. Tout retirer

`terraform plan -destroy -out=tfplan` dans `envs/shared-prod`, contrôle `check-plan-additions-only.sh --destroy tfplan.json` (`OK (destruction)` : seulement nos ressources et nos ajouts), relecture et accord du product owner, puis `terraform apply tfplan` : retire toutes nos ressources et les points de contact 1 à 3 (règles, certificat, règle du groupe de sécurité). Le dépôt ECR, le bucket de contenu et celui des sauvegardes de production sont protégés (`force_destroy = false`) : les vider d'abord (sauvegardes : après leur durée de conservation). Puis, avec le compte maître, supprimer nos bases et nos rôles (requêtes de l'[ADR § 5](../infra/hebergement-mutualise.md#5-points-de-contact-sur-les-ressources-de-cinaf-et-leur-retour-arrière)). Enfin, dans Google Cloud, supprimer l'abonnement push RTDN.
