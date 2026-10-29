# ADR — Hébergement mutualisé d'Eventide dans le compte AWS principal

| | |
|---|---|
| **Statut** | **Proposé.** Code Terraform écrit le 28 octobre 2026, durci le même jour pour la non-influence sur les autres plateformes (§ 11) ; **rien n'est appliqué** et aucun plan n'a été lancé contre AWS (seulement `terraform validate` et `terraform test` avec des fournisseurs simulés). Chaque `apply` exige le contrôle `check-plan-additions-only.sh` vert puis l'accord du product owner après relecture du plan ([runbook](../runbooks/premier-deploiement.md#avant-chaque-apply--contrôle-et-relecture-obligatoires)). |
| **Modèle suivi** | L'hébergement mutualisé de Candidature Express (ADR du 9 octobre 2026, dépôt `fabriceTAKOUMBO/Candidatureexpress`, `docs/infra/hebergement-mutualise.md`) : mêmes règles, mêmes garde-fous, mêmes quatre sortes de points de contact. |
| **Code** | [`infra/terraform/bootstrap`](../../infra/terraform/bootstrap), [`infra/terraform/envs/shared-prod`](../../infra/terraform/envs/shared-prod), modules [`shared_platform`](../../infra/terraform/modules/shared_platform), [`db_tools`](../../infra/terraform/modules/db_tools), [`content_cdn`](../../infra/terraform/modules/content_cdn) |
| **Runbooks** | [Premier déploiement](../runbooks/premier-deploiement.md), [coûts estimés](../runbooks/couts-estimes.md) |

## 1. Contexte

Eventide est une application Android (paysages vivants avec leurs sons, mélodies et minuteur ; micro et assistant vocal retirés le 29 octobre 2026). Son serveur doit : émettre un identifiant d'installation après contrôle Play Integrity, vérifier les achats Google Play et recevoir leurs notifications en temps réel (RTDN), enregistrer les partages de scènes et délivrer des adresses signées pour le contenu ([contrat](../api/contrat-v1.md)).

Le dossier d'analyse proposait API Gateway, Lambda, DynamoDB et Cognito dans une région européenne. Le product owner a retenu une autre voie, déjà éprouvée par Candidature Express : **un service Django sur ECS Fargate et PostgreSQL**, hébergé **dans le compte AWS principal `466494951409` (`us-east-1`)**, à côté de **CINAF** (streaming), **JobMinutes** et **Candidature Express**, en réutilisant leur réseau, leur répartiteur et leur instance de base de données. Avant d'avoir des utilisateurs, l'objectif est de payer le moins possible sans mettre en danger les produits voisins.

## 2. Décision

Déployer Eventide **dans le compte principal, en `us-east-1`**, en invité :

- réutiliser **le VPC, les sous-réseaux privés « application », la NAT, l'ALB `cinaf-streaming-prod-alb` (écouteur 443) et l'instance PostgreSQL 16 `cinaf-streaming-prod-postgres`** de CINAF, **seulement en lecture** (sources `data` de Terraform) ;
- **n'y poser que des ajouts, chacun réversible**, sans jamais modifier, supprimer ni lire le contenu d'une ressource d'un autre produit ; un plan qui affiche un `change` ou un `destroy` sur une ressource partagée est un bogue ;
- tout le reste est **à nous** : cluster ECS `ev-prod` (Fargate ARM64), groupe cible, groupes de sécurité, base `eventide` et rôles `ev_*`, secrets `eventide/prod/*`, clé KMS `alias/ev-prod`, journaux, alarmes, sujet SNS, sauvegardes logiques, contenu (S3 privé + CloudFront), rôle de déploiement GitHub, budget filtré sur l'étiquette `Project = eventide` ;
- **pas de Redis/Valkey** : les limites de débit, les quotas et le plafond de coût sont des mises à jour conditionnelles atomiques dans PostgreSQL ;
- **pas d'entrée publique tant que le domaine n'est pas acheté** (`domain_name = ""`, vérification de la marque en cours) : ni certificat, ni règle d'écouteur, ni DNS, ni service `api` ; la base, le contenu, l'image et les tâches peuvent exister avant ;
- préproduction **facultative**, éteinte par défaut (§ 7).

## 3. Vue d'ensemble

| Couche | Ressource | Propriétaire | Remarque |
|---|---|---|---|
| DNS | Zone publique `<domaine>` (cherchée par son nom) | Eventide (créée à l'achat du domaine) | `api.<domaine>` → API ; `<domaine>` et `www.<domaine>` → la même API (pages web du § 9 du contrat) ; validation ACM, CAA facultatif. Rien tant que `domain_name` est vide |
| Entrée | ALB `cinaf-streaming-prod-alb`, écouteur 443 | **CINAF** | Nos **règles 400 et 401** (plage réservée 400 à 409 ; préproduction 420 à 429) + notre certificat ACM ajouté à l'écouteur |
| Entrée | Groupe cible `ev-prod-api` (type ip, contrôle `/v1/health`) | Eventide | |
| Calcul | Cluster ECS `ev-prod` : service `api`, tâches `migrate`, `jobs`, `db-bootstrap`, `db-backup`, `db-restore-test` | Eventide | Sous-réseaux privés « application » de CINAF, Fargate ARM64 ; Container Insights coupé |
| Données | Instance RDS `cinaf-streaming-prod-postgres` (PostgreSQL 16, mono-AZ) | **CINAF** | Notre base `eventide`, nos rôles `ev_app`, `ev_migrator`, `ev_backup` ; base vide `eventide_restore` pour les tests de restauration |
| Sortie | NAT de CINAF (us-east-1a) | **CINAF** | Appels à Google (Play, Play Integrity, jetons), à AWS et aux journaux |
| Contenu | Bucket `ev-prod-content-466494951409` (privé, SSE-S3) + distribution CloudFront propre (OAC, groupe de clés pour les adresses signées) | Eventide | Clé privée de signature générée par Terraform, gardée dans `eventide/prod/cloudfront-private-key` |
| Secrets | Secrets Manager `eventide/prod/*`, clé KMS `alias/ev-prod` | Eventide | La clé refuse le déchiffrement à tout autre principal (§ 6) |
| Planification | EventBridge Scheduler `ev-prod` (fuseau Europe/Brussels) | Eventide | `purge-expired` 03 h 10, `finalize-purchases` chaque heure à 20, `db-backup` 03 h 40 |
| Observabilité | Groupes de journaux `/ecs/ev-prod/api` et `/ecs/ev-prod/jobs`, alarmes `ev-prod-*` (dont 5 sur la charge de l'instance partagée, métriques seulement), sujet SNS `ev-prod-alerts` (chiffré par notre clé) | Eventide | |
| Déploiement | Rôle `ev-prod-github-deploy`, registraire des définitions de tâche `ev-prod-task-registrar` (Lambda) | Eventide | Fournisseur OIDC GitHub **existant** (créé par JobMinutes), seulement référencé ; le rôle ne lit ni n'écrit aucune définition de tâche lui-même (§ 11) |
| Sauvegardes | Bucket `ev-prod-db-backups-466494951409` | Eventide | `pg_dump` quotidien, 35 jours |
| Coûts | Budget `eventide-mensuel`, budget `ev-prod-content-mensuel`, moniteur d'anomalies | Eventide | Filtrés sur `Project = eventide` |

Flux d'une requête de l'application :

| Étape | De | Vers | Contrôle |
|---|---|---|---|
| 1 | Téléphone | ALB partagé, 443 | TLS (politique de l'écouteur de CINAF) ; notre certificat choisi par SNI |
| 2 | ALB | Règle 400 (`api.`) ou 401 (domaine nu, `www`) | Correspondance sur nos seuls noms d'hôte |
| 3 | ALB | Tâche `api` (port 8000) | Groupe `ev-prod-api` : entrée seulement depuis le groupe de l'ALB |
| 4 | Tâche `api` | PostgreSQL partagé (5432) | Sortie limitée au groupe de la base ; TLS `verify-full` avec le bundle RDS embarqué dans l'image |
| 5 | Tâche `api` | Google (443) par la NAT | Jetons et clés lus dans nos secrets ; aucune phrase journalisée |
| 6 | Téléphone | CloudFront `ev-prod-content` | Adresse signée (1 h) délivrée par `POST /v1/content/urls` après contrôle des droits |

## 4. Ce qui est partagé, ce qui est isolé

| Partagé (et ce que cela implique) | Isolé |
|---|---|
| VPC, sous-réseaux « application », NAT unique, routage | Groupe de sécurité `ev-prod-api` et ses règles (entrée depuis l'ALB, sortie 443 et 5432 vers le seul groupe de la base) |
| ALB et son écouteur 443 (politique TLS, délai d'inactivité, journaux d'accès, absence de WAF : réglages de CINAF) | Groupe cible, règles d'hôte, certificat, contrôle de santé |
| Instance PostgreSQL (CPU, mémoire, disque, connexions, maintenance, instantanés de CINAF, compte maître) | Base, rôles, droits, limites de connexions, délais par rôle, sauvegardes logiques, base de test de restauration |
| Compte AWS (quotas Fargate, règles d'écouteur, certificats par ALB, distributions CloudFront, franchises gratuites, administrateurs) | Cluster ECS, dépôt ECR, secrets, clé KMS, journaux, alarmes, sujet SNS, rôles IAM, contenu S3 et CloudFront, budgets filtrés par étiquette |
| Fournisseur OIDC GitHub | Rôle de déploiement, restreint au dépôt `fabriceTAKOUMBO/eventide` (sujet OIDC immuable, variable `github_subject_repository`), à l'environnement GitHub `prod` et à `refs/heads/main` |

Toutes nos ressources portent `Project = eventide`, `Environment`, `ManagedBy = terraform`, `Repository = fabriceTAKOUMBO/eventide`, `Hosting = shared`. La clé `Project` est celle des autres produits du compte : une seule étiquette de répartition des coûts sert tout le monde.

## 5. Points de contact sur les ressources de CINAF et leur retour arrière

Les seuls objets posés **sur** des ressources d'un autre produit sont les quatre suivants : les mêmes sortes que Candidature Express, rien d'autre. Les points 1 et 2 n'existent qu'une fois `domain_name` renseigné.

| # | Ressource de CINAF | Notre ajout (ressource Terraform) | Effet sur CINAF, JobMinutes et Candidature Express | Retour arrière |
|---|---|---|---|---|
| 1 | Écouteur 443 de `cinaf-streaming-prod-alb` | 2 règles par nom d'hôte : 400 `api.<domaine>` et 401 `<domaine>`, `www.<domaine>`, vers notre groupe cible (`module.prod.module.alb[0].aws_lb_listener_rule.api` et `.web`) ; préproduction 420 et 421 | Aucun sur leurs hôtes : nos règles ne correspondent qu'à nos noms ; leurs priorités (100, 200, 210, 300 à 329) et l'action par défaut restent inchangées. La plage est vérifiée par Terraform (400 à 409, 420 à 429) | `terraform destroy -target=module.prod.module.alb` ; ou suppression des règles 400 et 401 dans la console |
| 2 | Écouteur 443 | Notre certificat ACM (`api.`, domaine nu, `www`) ajouté à la liste (`module.prod.module.alb[0].aws_lb_listener_certificate.this`) | Aucun : le certificat par défaut de CINAF reste servi à ses hôtes ; le nôtre n'est choisi que pour nos noms (SNI). Quota : 25 certificats par ALB | `terraform destroy -target=module.prod.module.alb[0].aws_lb_listener_certificate.this` (ou « Retirer » dans la console de l'écouteur) |
| 3 | Groupe de sécurité `sg-070b4372d5a95ad2d` de la base | 1 règle d'entrée 5432 autonome depuis notre groupe `ev-prod-api` (`module.prod.aws_vpc_security_group_ingress_rule.shared_postgres`) | Aucun : règle autonome, les règles existantes ne sont pas touchées | `terraform destroy -target=module.prod.aws_vpc_security_group_ingress_rule.shared_postgres` (nos tâches perdent alors la base) |
| 4 | Instance PostgreSQL (contenu) | Rôles `ev_app`, `ev_migrator`, `ev_backup` et bases `eventide`, `eventide_restore`, créés par la tâche `ev-prod-db-bootstrap` (une fois, avec le mot de passe maître fourni temporairement) | Connexions : **14 au plus** (10 + 2 + 2) ; stockage : quelques centaines de Mo la première année ; aucun paramètre, rôle ni base des autres n'est modifié | Encadré ci-dessous |
| — | Groupe de sécurité de l'ALB | **Aucune modification** : notre groupe le cite comme source autorisée | — | — |
| — | NAT, tables de routage, attributs de l'ALB, action par défaut de l'écouteur, paramètres RDS, fournisseur OIDC | **Aucune modification** (lecture seule) | — | — |

Retrait de la base (après une dernière sauvegarde), connecté avec le compte maître :

```sql
REVOKE CONNECT ON DATABASE eventide FROM ev_app, ev_backup;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname LIKE 'eventide%';
DROP DATABASE eventide;
DROP DATABASE eventide_restore;
DROP ROLE ev_app; DROP ROLE ev_backup; DROP ROLE ev_migrator;
```

Préproduction activée : mêmes requêtes avec `eventide_preprod`, `eventide_preprod_restore` et `ev_preprod_app`, `ev_preprod_migrator`, `ev_preprod_backup`.

Ce qui est seulement **lu** (sources `data`) : le VPC, les sous-réseaux, l'ALB et son écouteur 443, l'instance PostgreSQL et son groupe de sécurité, le fournisseur OIDC GitHub. La zone Route 53 est la nôtre (le plan échoue si elle ne porte pas `Project = eventide`). Le contrôle `.github/scripts/check-shared-account-resources.sh` (CI Infra, repris de Candidature Express, étendu le 28 octobre 2026) refuse dans le code les types de ressources qui agissent sur tout le compte ou toute une région (GuardDuty, Security Hub, Config, réglages par défaut d'EC2, d'ECS ou d'ECR, fournisseur OIDC, etc.), ceux de l'infrastructure partagée (ALB, écouteur, RDS, VPC, routes, points de terminaison VPC, DNS privé…), les points de contact hors de leurs fichiers et les modules non locaux. Avant chaque `apply`, `.github/scripts/check-plan-additions-only.sh` contrôle le plan lui-même (§ 11). Aucun des deux ne remplace la relecture du plan.

**À confirmer côté CINAF (lecture de leur Terraform, pas de changement)** : si le groupe de sécurité de la base ou l'écouteur 443 sont décrits avec des règles intégrées (`ingress {}`, règles dans la ressource de l'écouteur), un `terraform apply` de CINAF supprimerait nos ajouts (et ceux de JobMinutes et de Candidature Express). La présence des règles des deux autres invités laisse penser que non ; à vérifier.

## 6. Isolement et sécurité

**Base partagée.**

- La tâche `ev-prod-db-bootstrap` crée nos rôles et nos bases avec le compte maître, lu dans un secret **temporaire** (`eventide/prod/bootstrap/rds-master-password`) que le product owner crée puis supprime aussitôt. Le mot de passe maître reste gardé par CINAF ; ni Terraform, ni nos tâches permanentes, ni les agents ne le lisent. Les mots de passe de nos rôles partent sous forme de **vérificateurs SCRAM** calculés dans la tâche (conteneur `scram`) : ils n'apparaissent ni dans les journaux de l'instance, ni dans `pg_stat_statements`.
- `REVOKE ALL ON DATABASE … FROM PUBLIC` : seuls nos rôles entrent dans nos bases. Le compte maître n'y garde **aucun accès permanent** : son appartenance temporaire à `ev_migrator` est retirée à la fin de l'amorçage, et aussi en cas d'échec (seconde connexion, [`bootstrap_cleanup.sql`](../../infra/terraform/modules/db_tools/files/bootstrap_cleanup.sql) ; à défaut, l'événement `db_bootstrap_cleanup_failed` donne la commande `REVOKE` à lancer).
- Nos rôles portent le commentaire `eventide`, posé à leur création. Si un rôle du même nom existe sans ce marqueur, l'amorçage s'arrête **sans le modifier**.
- `ev_app` : DML seulement. `ev_migrator` : propriétaire du schéma (migrations). `ev_backup` : lecture seule (`pg_dump`).
- Limites : `ev_app` **10**, `ev_migrator` **2**, `ev_backup` **2**, **base 14**. Le plan Terraform échoue (`terraform_data.connection_budget`) si `api.max × workers × pool × chevauchement de déploiement + réserve des tâches planifiées` dépasse la limite de `ev_app` (production : 2 × 1 × 2 × 2 + 2 = 10), ou si la somme des limites dépasse le budget de 14. Le pool de connexions de Django (`DB_POOL_MAX_SIZE = 2` par worker) borne les connexions d'une tâche ; la connexion est rendue au pool pendant l'appel au modèle.
- Délais par rôle (comme Candidature Express) : `ev_app` 30 s par requête, 5 s d'attente de verrou, 60 s d'inactivité en transaction ; `ev_migrator` 15 min, 10 s, 5 min ; `ev_backup` sans limite de requête, 60 s, 10 min.
- Plafonds de ressources par rôle (28 octobre 2026, § 11) : `work_mem` 4 Mo (`ev_migrator` 16 Mo), `maintenance_work_mem` 16 Mo (`ev_migrator` 64 Mo), aucun worker parallèle (`max_parallel_workers_per_gather = 0`, `max_parallel_maintenance_workers = 0`), sessions inactives fermées par le serveur (`idle_session_timeout` 15 min pour `ev_app`, 10 min sinon ; le pool de Django vérifie une connexion avant de la donner), `temp_file_limit` 256 Mo (`ev_migrator` 1 Go) si le compte maître a le droit `SET` sur ce paramètre réservé au superutilisateur (sinon signalé par `db_bootstrap_temp_file_limit_skipped`). Tous posés par `ALTER ROLE … SET`, vérifiés contre PostgreSQL 16 avec un compte maître non superutilisateur.
- Une base `eventide*` existante qui n'appartient pas à notre rôle de migration arrête l'amorçage **avant toute modification** ; les scripts refusent au lancement tout nom de base hors `eventide*` et tout rôle hors `ev_*`, quelles que soient les surcharges d'une exécution.
- TLS : `sslmode=verify-full` avec le bundle d'autorités RDS (fichier embarqué dans l'image après contrôle d'empreinte ; outils PostgreSQL : même contrôle).
- Script testé contre un vrai PostgreSQL 16 avec un compte maître non superutilisateur, comme sur RDS ([`tests/run-local.sh`](../../infra/terraform/modules/db_tools/tests/run-local.sh), aussi lancé par la CI Infra), y compris les migrations de Django sous `ev_migrator` et les écritures de l'API sous `ev_app`.

**Ce qui n'est pas isolable sur une instance partagée** : le compte maître de CINAF (membre de `rds_superuser`) peut toujours prendre la main sur nos rôles et lire nos données. Une compromission de CINAF expose donc les données d'Eventide (identifiants d'installation, empreintes d'appareils, identifiants Google `sub`, achats, partages). Les données d'Eventide sont peu sensibles (aucune phrase, aucun nom, aucune adresse e-mail), mais le risque est réel.

**Clé KMS.** Une clé par environnement (`alias/ev-prod`, 1 USD/mois). Une règle de **refus explicite** empêche tout déchiffrement par un principal autre que nos rôles `ev-<env>-*`, les rôles Identity Center du jeu d'autorisations **AdministratorAccess** (`kms_admin_principal_arns`) et ceux de `kms_extra_decrypt_principal_arns`, même s'ils ont `kms:*` par IAM : rôles des autres produits, autres jeux d'autorisations, utilisateurs IAM, rôles de déploiement des autres dépôts. Le plan avertit (bloc `check "terraform_session_can_decrypt"`) si la session Terraform ne pourra pas déchiffrer : ne pas appliquer un tel plan. Retour arrière si un usage légitime est refusé : `kms_restrict_decrypt = false`, puis `apply`.

**État Terraform.** L'état de `envs/shared-prod` contient **des secrets en clair** (mots de passe des rôles PostgreSQL, clé Django, clé privée de signature CloudFront). Le bucket `eventide-tfstate-466494951409` et sa clé `alias/eventide-tfstate` (pile `bootstrap`) refusent explicitement la lecture, l'écriture, la suppression et le déchiffrement des objets à tout principal hors de `state_access_principal_arns` (par défaut : les seuls rôles Identity Center AdministratorAccess du compte). L'administration des politiques reste possible pour un administrateur du compte, qui peut donc toujours lire l'état : c'est le niveau d'isolement atteignable dans un compte partagé. La pile `bootstrap` garde son état en local (bloc `check "terraform_session_can_use_state"`).

**Réseau.** Entrée dans nos tâches seulement depuis le groupe de l'ALB ; sortie vers 443 (Internet, par la NAT) et 5432 vers le seul groupe de la base. Le plan échoue (préconditions) si l'ALB ne traite plus `X-Forwarded-For` en mode `append` sans port client (limites de débit par IP, `NUM_PROXIES = 1`), s'il reste moins de 30 adresses libres dans un sous-réseau « application », si les sous-réseaux ne sont pas dans le VPC, si le groupe de sécurité n'est pas celui de l'instance, si l'instance n'est plus en PostgreSQL 16 ou si la zone trouvée ne correspond pas au domaine.

**Sans WAF.** Aucun WAF ne peut être ajouté à l'ALB partagé (il s'appliquerait aux autres produits). Protections : limites de débit de l'application (par IP, appareil et installation, tenues dans PostgreSQL), Play Integrity à la création d'installation.

**Secrets applicatifs.** Clé Django, mots de passe des rôles et clé de signature CloudFront générés par Terraform ; clé JSON du compte de service Google Play déposée à la main par le product owner (valeur provisoire `A_REMPLACER`, que l'API traite comme « non configuré » : 503 et alarme `ev-prod-google-not-configured`). Les rôles d'exécution ne lisent que nos secrets. Les tâches `api`, `migrate` et `jobs` n'ont **aucun rôle de tâche** (aucun droit AWS à l'exécution) ; seules les tâches de sauvegarde et de test de restauration en ont un, limité à notre bucket de sauvegardes et à notre clé.

## 7. Préproduction

`preprod_enabled = false` par défaut. Activée, elle crée dans la même pile un environnement séparé : cluster `ev-preprod`, base `eventide_preprod` et rôles `ev_preprod_*` (6 connexions au plus : 4 + 1 + 1), hôtes `api.preprod.<domaine>` et `preprod.<domaine>`, règles 420 et 421, Fargate Spot, service `api` allumé de 8 h à 20 h les jours ouvrés (heure de Bruxelles) et éteint sinon, clé KMS `alias/ev-preprod`, secrets `eventide/preprod/*`, contenu propre. Recommandation : l'activer quand des testeurs arrivent, pas avant ([coûts](../runbooks/couts-estimes.md)).

## 8. Risques

| Risque | Gravité | Parade |
|---|---|---|
| **Base mono-AZ partagée** : une panne arrête CINAF, JobMinutes, Candidature Express et Eventide ; restauration par CINAF (instantanés) ou par nous (`pg_dump` de la veille, RPO ≤ 24 h) | Élevée | Sauvegarde logique quotidienne, test de restauration ([runbook](../runbooks/premier-deploiement.md) § 12) ; passage à un compte dédié quand le chiffre d'affaires dépend de la disponibilité |
| **Voisin bruyant** dans les deux sens : un pic d'un autre produit ralentit nos requêtes, ou nos requêtes consomment le CPU et les crédits de l'instance | Moyenne | 14 connexions au plus, délais et plafonds de ressources par rôle (§ 6) ; 5 alarmes de charge de l'instance en production (`rds_alarms_enabled`, lecture des seules métriques) ; requêtes courtes (compteurs par clé unique) |
| **Pas de WAF** : ni réputation IP, ni règles gérées, ni limite par IP en amont | Moyenne | Limites de débit dans l'application, Play Integrity, plafonds de coût ; à terme un compte dédié |
| Une évolution de l'infrastructure de CINAF supprime nos ajouts (règles intégrées dans son Terraform, recréation de l'ALB, de l'écouteur ou de la base) | Moyenne | Vérification demandée (§ 5) ; alarmes `ev-prod-api-unhealthy` et `ev-prod-api-5xx` ; plan Terraform régulier qui révèle les dérives |
| Montée de version majeure de l'instance par CINAF (17) | Faible | Le plan échoue (précondition « PostgreSQL 16 ») ; l'alarme `ev-prod-db-backup-missing` se déclenche ; mettre à jour l'image de `db_tools` |
| NAT unique en us-east-1a : une panne de zone coupe Google (Play, Play Integrity) | Faible | Accepté (comme les autres invités) ; l'écoute n'en dépend pas ; les achats sont revérifiés plus tard (`finalize-purchases`) |
| Politique TLS et délai d'inactivité de l'écouteur choisis par CINAF | Faible | Keep-alive de gunicorn calculé à partir du délai lu par Terraform (délai + 5 s, 75 s au moins) |
| Fournisseur OIDC GitHub géré par le Terraform de JobMinutes : sa suppression casse nos déploiements | Faible | Le recréer à l'identique ; dépendance à noter chez JobMinutes |
| Le rôle de notre registraire (`ev-prod-task-registrar`) garde `ecs:RegisterTaskDefinition` sur `*` : restriction par famille non vérifiée (la Service Authorization Reference et le guide d'ECS se contredisent) | Faible | **Corrigé côté déploiement le 28 octobre 2026** : le rôle GitHub n'a plus ni `ecs:RegisterTaskDefinition` ni `ecs:DescribeTaskDefinition` (il ne lit donc plus les définitions de tâche des autres produits, variables en clair comprises) ; il n'appelle que le registraire, qui n'accepte qu'une de nos familles et un SHA, à partir du modèle écrit par Terraform. Seul un `apply` approuvé change ce code. À restreindre par ARN une fois vérifié dans le compte membre (§ 11) |
| Chevauchement de déploiement (`deployment_maximum_percent = 200`) : jusqu'à 4 tâches `api` un court instant | Faible | Compté dans le budget de connexions (le plan échoue sinon) |
| Quotas du compte partagés (vCPU Fargate, 100 règles par écouteur, 25 certificats par ALB, distributions, clés et politiques de cache CloudFront, rôles IAM) | Faible | 2 règles et 1 certificat par environnement, 2 tâches `api` au plus ; le plan échoue au-delà de 2 vCPU Fargate au pic par environnement (`fargate_vcpu_budget`) ; quota réel à lire (runbook § 4) |
| **Coûts portés par les ressources de CINAF** : données traitées par la NAT (images de nos tâches : jusqu'à ≈ 4 USD/mois sans point de terminaison S3), unités de capacité de l'ALB, nos données dans les instantanés de l'instance | Faible | Signalés (règle 5) ; chiffrés au § 11 et dans les [coûts](../runbooks/couts-estimes.md) ; parades à décider (§ 11.4) |
| **Franchise gratuite de CloudFront partagée** (1 To et 10 millions de requêtes par mois pour tout le compte, très probablement consommée par CINAF, produit de streaming) | Moyenne | Coût du contenu calculé sans franchise ([coûts](../runbooks/couts-estimes.md)) ; budget `ev-prod-content-mensuel` et alarmes de volume ; formule CloudFront à prix fixe à étudier |
| Coûts mélangés avec ceux des autres produits | Faible | Étiquette `Project` active dans Billing ; budget et anomalies filtrés dessus |
| Compte sans CloudTrail ni GuardDuty (constat de Candidature Express le 9 octobre 2026, non revérifié) | Moyenne | Recommandé au product owner pour toute l'organisation |
| **Hébergement aux États-Unis** (RGPD) : la base, les sauvegardes, les journaux et l'origine du contenu sont à `us-east-1` | Moyenne | Transfert couvert par l'*EU-US Data Privacy Framework* (adhésion d'AWS et de Google à vérifier) et, à défaut, par les clauses types ; **la politique de confidentialité le dit** (`backend/apps/web/templates/web/confidentialite.html`, § « Où sont vos données » : « États-Unis (Virginie du Nord) ») ; aucun son ni aucune voix n'est enregistré (l'application n'utilise pas le micro). Le dossier recommandait une région européenne : écart assumé par la décision du product owner |

## 9. Passage à un compte dédié (plus tard)

À déclencher quand le trafic arrive (repères : plus de 10 000 utilisateurs actifs par mois, base > 2 Go, ou besoin d'une base Multi-AZ), ou plus tôt si CINAF change d'infrastructure. Région à décider (une région de l'UE serait préférable pour le RGPD). Étapes : `bootstrap` dans le nouveau compte, environnement complet (réseau, ALB, base), `pg_dump` final par `ev-prod-db-backup` puis `pg_restore`, bascule DNS, puis `terraform destroy` de `envs/shared-prod` (retire les points de contact 1 à 3) et requêtes de retrait du § 5 (point 4). Le contenu (S3 + CloudFront) peut être recopié tel quel ; les adresses signées changent de clé.

## 10. Alternatives écartées

| Option | Pourquoi non |
|---|---|
| API Gateway, Lambda et DynamoDB (proposition du dossier) | Décision du product owner : même pile que Candidature Express (Django, PostgreSQL, ECS), déjà éprouvée et outillée dans ce compte ; les compteurs conditionnels se font aussi bien en SQL |
| Cognito pour la connexion Google | Hors v1 : un jeton d'identité Google vérifié par le serveur (`google.oauth2.id_token`) suffit pour rattacher une installation à un compte ; Cognito n'apporte pas l'usage anonyme par installation dont l'application a besoin. À reconsidérer si d'autres fournisseurs d'identité arrivent |
| Redis ou Valkey pour les limites de débit et quotas | Un coût fixe (≈ 9 USD/mois) sans besoin : les mises à jour conditionnelles atomiques de PostgreSQL suffisent au volume attendu |
| Compte dédié dès maintenant | Réseau, NAT, ALB et base propres : plusieurs centaines d'USD par mois sans utilisateurs |
| Instance RDS à nous dans le VPC partagé | +15 à 30 USD/mois (mono-AZ) ; à revoir si le voisinage pose problème |
| WAF sur l'ALB partagé | Modifierait le trafic des autres produits |
| Contenu servi par l'API ou par S3 public | Le contenu Premium doit rester protégé : S3 privé, CloudFront avec OAC et adresses signées |

## 11. Non-influence sur CINAF, JobMinutes et Candidature Express

Exigence du product owner (28 octobre 2026, [`AGENTS.md`](../../AGENTS.md), « RÈGLE ABSOLUE ») : **CINAF, JobMinutes et Candidature Express restent intouchées et ne doivent être influencées en aucun cas par ce que fait Eventide.** Revue complète du code le 28 octobre 2026, **sans aucun appel AWS** (lecture du code, `terraform validate` et `terraform test` avec fournisseurs simulés et sans identifiants, scripts PostgreSQL contre un PostgreSQL 16 local). Tout ce qui suit est vérifié par des tests, sauf mention contraire.

### 11.1 Inventaire

Compté sur les plans simulés (`terraform test -verbose`, `envs/shared-prod`) :

| Classe | Phase 1 (sans domaine) | Phase 2 (domaine) | Phase 2 + préproduction |
|---|---|---|---|
| (a) Ressources d'Eventide créées | 129 | 149 | 287 |
| (b) Objets posés **sur** une ressource de CINAF (les quatre sortes de § 5, rien d'autre) | 1 : règle 5432 | 4 : règle 5432, règles 400 et 401, certificat | 8 (420, 421, règle 5432 et certificat de préproduction en plus) |
| (c) Ressources des autres seulement lues (sources `data`) | 8 : VPC, 2 sous-réseaux, ALB, écouteur 443, instance PostgreSQL, son groupe de sécurité, fournisseur OIDC (JobMinutes) | les mêmes, plus **notre** zone Route 53 | les mêmes |
| Point de contact 4 (hors Terraform, tâche d'amorçage) | 3 rôles `ev_*` et 2 bases `eventide*` sur l'instance | idem | + 3 rôles `ev_preprod_*` et 2 bases `eventide_preprod*` |
| Modifications, remplacements, suppressions ou imports d'une ressource d'un autre produit | **0** | **0** | **0** |

### 11.2 Canaux d'influence, protections et risques résiduels

| Canal d'influence | Protection dans le code (et contrôle automatique) | Risque résiduel |
|---|---|---|
| **Modifier, remplacer, supprimer ou importer** une ressource d'un autre produit | Ressources partagées seulement lues (`data`). Contrôle statique `check-shared-account-resources.sh` : types de l'infrastructure partagée (ALB, écouteur, RDS, VPC, sous-réseaux, NAT, routes, anciennes règles de groupe…) et réglages du compte interdits dans le code ; points de contact limités à leurs fichiers. **Contrôle du plan `check-plan-additions-only.sh`, obligatoire avant chaque `apply`** : refuse toute action autre qu'un ajout hors de nos adresses, tout type partagé (même en `no-op` : notre état ne doit jamais en gérer), tout import d'un objet posé sur une ressource partagée, toute ressource hors de la liste d'Eventide ; liste à relire chaque modification de nos propres ressources | Un `apply` lancé sans le contrôle (la procédure l'interdit) ; une évolution de l'infrastructure de CINAF qui supprime nos ajouts (effet sur nous seulement, § 8) |
| **Règles d'écoute de l'ALB** (captation du trafic d'un autre produit) | Condition `host_header` seule, noms **exacts** (aucun joker, validation) et tous égaux à notre domaine ou à l'un de ses sous-domaines (précondition ; un suffixe trompeur comme `noteventide.app` est refusé) ; action `forward` vers notre groupe cible ; priorités 400-409 / 420-429, distinctes et dans le même bloc ; écouteur vérifié HTTPS 443 ; `domain_name` ne peut pas être `cinaf.tv`, `jobminutes.com`, `candidatureexpress.com` ni l'un de leurs sous-domaines ; la zone doit porter `Project = eventide`. Tests : module `alb` (11 cas), pile (7 cas). Le contrôle du plan revérifie priorité, noms, conditions et action | Aucun sur leurs hôtes. Nos règles venant après les leurs (100 à 329), leurs requêtes n'en évaluent aucune de plus ; seules les requêtes qui ne correspondent à aucune règle en évaluent 2 de plus |
| **Certificat** de l'écouteur | Ajouté à la liste (`aws_lb_listener_certificate`, choix SNI), jamais comme certificat par défaut ; aucune ressource `aws_lb_listener` possible (interdite) | Aucun |
| **Groupe de sécurité de la base** | Une règle autonome, tcp 5432, source = notre groupe, jamais de bloc CIDR ni de liste de préfixes (précondition et test) ; toute règle posée sur un groupe partagé ailleurs qu'à cette adresse est refusée par le contrôle du plan (les groupes partagés sont lus dans le plan) | Si le Terraform de CINAF décrit ce groupe avec des règles intégrées, son `apply` retire notre règle (à confirmer côté CINAF, § 5) |
| **Lire le contenu de leurs bases** | Nos rôles n'ont aucun droit sur leurs bases ; aucun nom de base hors `eventide*` ni de rôle hors `ev_*` (validations Terraform des modules `shared_platform` et `db_tools`, garde des scripts au lancement, testée) ; `REVOKE ALL ON DATABASE eventide FROM PUBLIC` | **Résiduel (à leur charge)** : nos rôles peuvent techniquement se connecter aux bases des autres qui laissent `CONNECT` et `TEMPORARY` à PUBLIC (défaut de PostgreSQL) et y lire ce qui est ouvert à PUBLIC. Nous ne pouvons pas modifier leurs bases ; notre code ne nomme jamais une autre base. Correctif côté CINAF, JobMinutes, Candidature Express : `REVOKE CONNECT, TEMPORARY ON DATABASE <leur base> FROM PUBLIC` |
| **Rôles et bases de l'instance** (amorçage avec le compte maître) | Marqueur `eventide` exigé sur nos rôles ; une base de l'un de nos noms qui n'appartient pas à notre rôle arrête tout **avant** la moindre modification ; aucun paramètre d'instance, aucun autre rôle ni aucune autre base modifiés ; appartenance temporaire du compte maître retirée, aussi après un échec ; secret temporaire chiffré par **notre** clé (runbook § 7). Tests contre PostgreSQL 16 : rôle étranger et base étrangère laissés intacts | Le compte maître de CINAF sert une fois : le product owner lit ce mot de passe dans un secret de CINAF, et l'appartenance temporaire touche brièvement ce rôle de CINAF. Alternative à décider : amorçage lancé par l'équipe CINAF, ou rôle d'amorçage délégué créé par elle (§ 11.4) |
| **Connexions de l'instance** | Limites par rôle 10 / 2 / 2 et base 14 (préproduction 6) ; pool de Django par worker ; le plan échoue si autoscaling × chevauchement de déploiement + réserve dépasse la limite de `ev_app` (production : 2 × 1 × 2 × 2 + 2 = 10) ; `idle_session_timeout` ferme nos sessions oubliées et le pool vérifie une connexion avant usage (`CONN_HEALTH_CHECKS`, testé : une connexion fermée par le serveur est remplacée) | `max_connections` est commun : marge à confirmer avec CINAF (runbook § 4) |
| **CPU, mémoire, disque, E/S de l'instance** | Délais par rôle ; `work_mem`, `maintenance_work_mem`, aucun worker parallèle, `temp_file_limit` (§ 6) ; requêtes courtes par clé unique ; une sauvegarde par jour (03 h 40, Bruxelles) ; test de restauration **manuel** seulement ; 5 alarmes de charge en production (CPU > 70 %, connexions > 300, mémoire < 256 Mo, disque < 10 Go, crédits < 100), métriques seulement : une alarme ne peut agir que par SNS (le contrôle du plan refuse toute autre action) | `work_mem` et voisins restent modifiables par une session de nos rôles (notre code ne le fait jamais) ; `temp_file_limit` n'est posé que si RDS donne le droit `SET` au compte maître (non vérifié) ; communs à l'instance et non bornables par nous : autovacuum de nos tables, identifiants de transaction (une écriture par requête pour les compteurs), journaux de l'instance et `pg_stat_statements` s'ils sont actifs chez CINAF (nos requêtes y figurent), nos données dans ses instantanés ; le test de restauration double un court instant notre stockage |
| **Lire leurs définitions de tâche** (variables en clair de CINAF) | Le rôle de déploiement n'a plus `ecs:DescribeTaskDefinition` (qui n'accepte que `*`) : les révisions sont construites à partir du modèle écrit par Terraform (module `ecs`, `register_inputs`) et embarqué dans notre registraire. Test du rôle : ni `DescribeTaskDefinition`, ni `RegisterTaskDefinition`, ni `*` | Aucun |
| **Écrire une révision dans leurs familles** (leurs services ou planifications qui suivent la dernière révision l'exécuteraient) | Le rôle de déploiement n'a plus `ecs:RegisterTaskDefinition` ; il appelle notre registraire (Lambda `ev-<env>-task-registrar`, hors VPC), qui n'accepte qu'une clé de nos familles (`api`, `migrate`, `jobs`) et un SHA de commit, refuse tout autre champ, fixe famille, rôles et conteneurs depuis le modèle de Terraform et étiquette la révision `Project = eventide` (9 tests unitaires) ; le script de déploiement vérifie la famille renvoyée (6 tests) | **Résiduel** : le rôle du registraire garde `ecs:RegisterTaskDefinition` sur `*` (restriction par famille non vérifiée) ; seul un `apply` approuvé peut changer le code qui l'utilise. À restreindre par ARN après vérification dans le compte membre |
| **Autres droits IAM** | Rôle de déploiement : chaque ressource est un ARN `ev-*` ou `/eventide/*` (validations des variables et test), sauf `ecr:GetAuthorizationToken` (jeton du compte, utilisable sur nos seuls dépôts) ; rôles d'exécution : nos secrets ; rôles de tâche : notre bucket ; planificateur : `RunTask` sur nos familles dans notre cluster ; `PassRole` limité à nos rôles | Aucun |
| **Réglages du compte ou de la région** | Liste du contrôle statique étendue le 28 octobre 2026 (réglages ECR, Backup, Glue, Lake Formation, politique, permissions et archives du bus d'événements par défaut, CloudTrail, fournisseurs SAML, Resource Explorer, Access Analyzer, activation d'étiquettes de coûts, ressources `aws_default_*`…), même liste dans le contrôle du plan ; runbook : plus d'activation de la clé `Environment` dans Billing (réglage de tout le compte) | Les rôles liés à un service (ECS, Application Auto Scaling) seraient créés par AWS s'ils n'existaient pas ; ils existent déjà (Candidature Express) |
| **Réseau partagé** (routage, DNS, adresses) | Aucun point de terminaison VPC, espace de noms DNS privé (Service Connect, Cloud Map), zone privée, règle Resolver, options DHCP, journal de flux ni miroir de trafic (interdits, testés) ; nos seuls groupes de sécurité ; sorties 443 et 5432 seulement | Adresses IP de leurs sous-réseaux : 7 au plus par environnement (4 tâches `api` pendant un déploiement + 3 ponctuelles), précondition ≥ 30 libres au plan ; connexions de la NAT vers Google : négligeables |
| **Journaux, événements, métriques** (lecture de leur contenu) | Filtres de métriques sur nos groupes `/ecs/ev-*` seulement (contrôle du plan) ; règle EventBridge limitée à l'ARN de notre cluster ; alarmes ALB sur notre groupe cible ; abonnements de journaux et archives d'événements interdits | Les métriques `AWS/RDS` lues sont celles de toute l'instance (charge, pas de contenu) |
| **Coûts portés par leurs ressources** (règle 5 : à signaler) | Tâches petites et peu nombreuses ; contenu servi par notre CloudFront (pas par l'ALB) ; registraire hors VPC | **Signalé** : NAT de CINAF ≈ 80 Go/mois d'images de nos tâches (≈ 26 tâches par jour, dont 24 `finalize-purchases`) si aucun point de terminaison S3 : ≈ 3,5 à 4 USD/mois ; ALB : < 1 USD/mois au lancement (≈ 0,01 LCU) ; nos données dans les instantanés de l'instance. Parades au § 11.4 |
| **Capacités communes du compte** | vCPU Fargate : le plan échoue au-delà de `fargate_vcpu_budget` (2 vCPU) au pic par environnement (production 1,75 ; préproduction en Spot 1,25) ; quotas consommés par environnement : 2 règles et 1 certificat sur l'ALB (sur 100 et 25), 1 clé publique, 1 groupe de clés et 1 politique de cache CloudFront (sur 10, 10 et 20 par compte), 11 rôles IAM, concurrence Lambda non réservée (quelques appels par déploiement) | Le quota Fargate réel du compte est à lire (runbook § 4) |
| **Noms et étiquettes** (collisions) | Préfixes `ev-` / `eventide` validés (bases, rôles, registraire, ARN du rôle de déploiement) ; `Project = eventide` par `default_tags` et sur les révisions du registraire ; le contrôle du plan vérifie l'étiquette et le nom de chaque création | Aucun |
| **Appels AWS des agents** | Tests avec fournisseurs simulés et sans identifiants ; CI Infra sans identifiants (`AWS_EC2_METADATA_DISABLED`) | Aucun |

### 11.3 Contrôles automatiques

| Contrôle | Où | Ce qu'il prouve |
|---|---|---|
| `check-shared-account-resources.sh` (+ `tests/check-shared-account-resources.test.sh`, 9 cas) | CI Infra | Aucun type partagé ou de compte dans le code ; points de contact dans leurs seuls fichiers |
| `check-plan-additions-only.sh` (+ `tests/check-plan-additions-only.test.sh`, 11 cas sur des plans JSON : plan sain phases 1 et 2, mise à jour d'une ressource de CINAF, remplacement de l'écouteur, réglages du compte, règles d'écouteur fautives, règle 5432 ouverte, import, noms et étiquettes, destruction) | CI Infra (sur les plans de test) ; **runbook, avant chaque `apply`, sur le vrai plan** | Le plan n'ajoute que nos ressources et nos quatre sortes de points de contact |
| `terraform test` (fournisseurs simulés) | CI Infra | Règles d'écouteur (hôtes, priorités, écouteur 443), règle 5432 (port, source, sans CIDR), budget de connexions, budget vCPU, noms, domaine d'un autre produit refusé, zone non étiquetée refusée, rôle de déploiement sans accès aux définitions de tâche, registraire minimal |
| `run-local.sh` (PostgreSQL 16, compte maître non superutilisateur) | CI Infra | Amorçage limité à nos rôles et bases, plafonds par rôle effectifs, refus des noms et des objets étrangers, pool de Django après fermeture d'une session par le serveur |
| Tests du registraire (`tests/test_handler.py`) et de `register-task-revision.sh` | CI Infra | Aucune révision possible hors de nos familles |

### 11.4 Décisions du product owner

1. **Coût sur la NAT de CINAF** (jusqu'à ≈ 4 USD/mois) : le signaler à l'équipe CINAF ; option à décider : `finalize-purchases` toutes les 6 heures au lieu de chaque heure (≈ 4 fois moins de téléchargements d'images ; Google rembourse un achat non acquitté après 3 jours). Un point de terminaison S3 relève de CINAF (il modifierait ses routes) : jamais par nous.
2. **Mot de passe maître de CINAF** lu une fois par le product owner pour l'amorçage : accepter, ou demander à CINAF de lancer l'amorçage ou de créer un rôle d'amorçage délégué (`CREATEROLE`, `CREATEDB`).
3. **Registraire** : accepter `ecs:RegisterTaskDefinition` sur `*` pour son seul rôle, ou tester la restriction par famille dans le compte membre puis la poser.
4. **Accès PUBLIC aux bases des autres produits** : leur suggérer `REVOKE CONNECT, TEMPORARY … FROM PUBLIC` sur leurs bases (leur décision, leur changement).
5. **`temp_file_limit`** : si l'amorçage signale `db_bootstrap_temp_file_limit_skipped`, l'accepter (les autres plafonds tiennent) ou demander à CINAF le droit `SET` sur ce paramètre pour le compte maître.
