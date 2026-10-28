# ADR — Hébergement mutualisé d'Eventide dans le compte AWS principal

| | |
|---|---|
| **Statut** | **Proposé.** Code Terraform écrit le 28 octobre 2026 ; **rien n'est appliqué** et aucun plan n'a été lancé contre AWS (seulement `terraform validate` et `terraform test` avec des fournisseurs simulés). Chaque `apply` attend l'accord du product owner après relecture du plan ([runbook](../runbooks/premier-deploiement.md)). |
| **Modèle suivi** | L'hébergement mutualisé de Candidature Express (ADR du 9 octobre 2026, dépôt `fabriceTAKOUMBO/Candidatureexpress`, `docs/infra/hebergement-mutualise.md`) : mêmes règles, mêmes garde-fous, mêmes quatre sortes de points de contact. |
| **Code** | [`infra/terraform/bootstrap`](../../infra/terraform/bootstrap), [`infra/terraform/envs/shared-prod`](../../infra/terraform/envs/shared-prod), modules [`shared_platform`](../../infra/terraform/modules/shared_platform), [`db_tools`](../../infra/terraform/modules/db_tools), [`content_cdn`](../../infra/terraform/modules/content_cdn) |
| **Runbooks** | [Premier déploiement](../runbooks/premier-deploiement.md), [coûts estimés](../runbooks/couts-estimes.md) |

## 1. Contexte

Eventide est une application Android (sons de nature sur des photos de paysages, réglables à la voix). Son serveur doit : émettre un identifiant d'installation après contrôle Play Integrity, vérifier les achats Google Play et recevoir leurs notifications en temps réel (RTDN), tenir le compteur d'essai (3 demandes à vie) et le plafond de coût de l'assistant (2 € par mois et par abonné), traduire une phrase en actions par un modèle Gemini Flash-Lite, enregistrer les partages de scènes et délivrer des adresses signées pour le contenu ([contrat](../api/contrat-v1.md)).

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
| Sortie | NAT de CINAF (us-east-1a) | **CINAF** | Appels à Google (Gemini, Play, Play Integrity, jetons), à AWS et aux journaux |
| Contenu | Bucket `ev-prod-content-466494951409` (privé, SSE-S3) + distribution CloudFront propre (OAC, groupe de clés pour les adresses signées) | Eventide | Clé privée de signature générée par Terraform, gardée dans `eventide/prod/cloudfront-private-key` |
| Secrets | Secrets Manager `eventide/prod/*`, clé KMS `alias/ev-prod` | Eventide | La clé refuse le déchiffrement à tout autre principal (§ 6) |
| Planification | EventBridge Scheduler `ev-prod` (fuseau Europe/Brussels) | Eventide | `purge-expired` 03 h 10, `finalize-purchases` chaque heure à 20, `db-backup` 03 h 40 |
| Observabilité | Groupes de journaux `/ecs/ev-prod/api` et `/ecs/ev-prod/jobs`, alarmes `ev-prod-*`, sujet SNS `ev-prod-alerts` (chiffré par notre clé) | Eventide | |
| Déploiement | Rôle `ev-prod-github-deploy` | Eventide | Fournisseur OIDC GitHub **existant** (créé par JobMinutes), seulement référencé |
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

Ce qui est seulement **lu** (sources `data`) : le VPC, les sous-réseaux, l'ALB et son écouteur 443, l'instance PostgreSQL et son groupe de sécurité, le fournisseur OIDC GitHub. La zone Route 53 est la nôtre. Le contrôle `.github/scripts/check-shared-account-resources.sh` (CI Infra, repris de Candidature Express) refuse les types de ressources qui agissent sur tout le compte ou toute une région (GuardDuty, Security Hub, Config, réglages par défaut d'EC2, d'ECS ou d'ECR, fournisseur OIDC, etc.) et les modules non locaux ; il ne remplace pas la relecture du plan.

**À confirmer côté CINAF (lecture de leur Terraform, pas de changement)** : si le groupe de sécurité de la base ou l'écouteur 443 sont décrits avec des règles intégrées (`ingress {}`, règles dans la ressource de l'écouteur), un `terraform apply` de CINAF supprimerait nos ajouts (et ceux de JobMinutes et de Candidature Express). La présence des règles des deux autres invités laisse penser que non ; à vérifier.

## 6. Isolement et sécurité

**Base partagée.**

- La tâche `ev-prod-db-bootstrap` crée nos rôles et nos bases avec le compte maître, lu dans un secret **temporaire** (`eventide/prod/bootstrap/rds-master-password`) que le product owner crée puis supprime aussitôt. Le mot de passe maître reste gardé par CINAF ; ni Terraform, ni nos tâches permanentes, ni les agents ne le lisent. Les mots de passe de nos rôles partent sous forme de **vérificateurs SCRAM** calculés dans la tâche (conteneur `scram`) : ils n'apparaissent ni dans les journaux de l'instance, ni dans `pg_stat_statements`.
- `REVOKE ALL ON DATABASE … FROM PUBLIC` : seuls nos rôles entrent dans nos bases. Le compte maître n'y garde **aucun accès permanent** : son appartenance temporaire à `ev_migrator` est retirée à la fin de l'amorçage, et aussi en cas d'échec (seconde connexion, [`bootstrap_cleanup.sql`](../../infra/terraform/modules/db_tools/files/bootstrap_cleanup.sql) ; à défaut, l'événement `db_bootstrap_cleanup_failed` donne la commande `REVOKE` à lancer).
- Nos rôles portent le commentaire `eventide`, posé à leur création. Si un rôle du même nom existe sans ce marqueur, l'amorçage s'arrête **sans le modifier**.
- `ev_app` : DML seulement. `ev_migrator` : propriétaire du schéma (migrations). `ev_backup` : lecture seule (`pg_dump`).
- Limites : `ev_app` **10**, `ev_migrator` **2**, `ev_backup` **2**, **base 14**. Le plan Terraform échoue (`terraform_data.connection_budget`) si `api.max × workers × pool × chevauchement de déploiement + réserve des tâches planifiées` dépasse la limite de `ev_app` (production : 2 × 1 × 2 × 2 + 2 = 10), ou si la somme des limites dépasse le budget de 14. Le pool de connexions de Django (`DB_POOL_MAX_SIZE = 2` par worker) borne les connexions d'une tâche ; la connexion est rendue au pool pendant l'appel au modèle.
- Délais par rôle (comme Candidature Express) : `ev_app` 30 s par requête, 5 s d'attente de verrou, 60 s d'inactivité en transaction ; `ev_migrator` 15 min, 10 s, 5 min ; `ev_backup` sans limite de requête, 60 s, 10 min.
- TLS : `sslmode=verify-full` avec le bundle d'autorités RDS (fichier embarqué dans l'image après contrôle d'empreinte ; outils PostgreSQL : même contrôle).
- Script testé contre un vrai PostgreSQL 16 avec un compte maître non superutilisateur, comme sur RDS ([`tests/run-local.sh`](../../infra/terraform/modules/db_tools/tests/run-local.sh), aussi lancé par la CI Infra), y compris les migrations de Django sous `ev_migrator` et les écritures de l'API sous `ev_app`.

**Ce qui n'est pas isolable sur une instance partagée** : le compte maître de CINAF (membre de `rds_superuser`) peut toujours prendre la main sur nos rôles et lire nos données. Une compromission de CINAF expose donc les données d'Eventide (identifiants d'installation, empreintes d'appareils, identifiants Google `sub`, achats, partages). Les données d'Eventide sont peu sensibles (aucune phrase, aucun nom, aucune adresse e-mail), mais le risque est réel.

**Clé KMS.** Une clé par environnement (`alias/ev-prod`, 1 USD/mois). Une règle de **refus explicite** empêche tout déchiffrement par un principal autre que nos rôles `ev-<env>-*`, les rôles Identity Center du jeu d'autorisations **AdministratorAccess** (`kms_admin_principal_arns`) et ceux de `kms_extra_decrypt_principal_arns`, même s'ils ont `kms:*` par IAM : rôles des autres produits, autres jeux d'autorisations, utilisateurs IAM, rôles de déploiement des autres dépôts. Le plan avertit (bloc `check "terraform_session_can_decrypt"`) si la session Terraform ne pourra pas déchiffrer : ne pas appliquer un tel plan. Retour arrière si un usage légitime est refusé : `kms_restrict_decrypt = false`, puis `apply`.

**État Terraform.** L'état de `envs/shared-prod` contient **des secrets en clair** (mots de passe des rôles PostgreSQL, clé Django, clé privée de signature CloudFront). Le bucket `eventide-tfstate-466494951409` et sa clé `alias/eventide-tfstate` (pile `bootstrap`) refusent explicitement la lecture, l'écriture, la suppression et le déchiffrement des objets à tout principal hors de `state_access_principal_arns` (par défaut : les seuls rôles Identity Center AdministratorAccess du compte). L'administration des politiques reste possible pour un administrateur du compte, qui peut donc toujours lire l'état : c'est le niveau d'isolement atteignable dans un compte partagé. La pile `bootstrap` garde son état en local (bloc `check "terraform_session_can_use_state"`).

**Réseau.** Entrée dans nos tâches seulement depuis le groupe de l'ALB ; sortie vers 443 (Internet, par la NAT) et 5432 vers le seul groupe de la base. Le plan échoue (préconditions) si l'ALB ne traite plus `X-Forwarded-For` en mode `append` sans port client (limites de débit par IP, `NUM_PROXIES = 1`), s'il reste moins de 30 adresses libres dans un sous-réseau « application », si les sous-réseaux ne sont pas dans le VPC, si le groupe de sécurité n'est pas celui de l'instance, si l'instance n'est plus en PostgreSQL 16 ou si la zone trouvée ne correspond pas au domaine.

**Sans WAF.** Aucun WAF ne peut être ajouté à l'ALB partagé (il s'appliquerait aux autres produits). Protections : limites de débit de l'application (par IP, appareil et installation, tenues dans PostgreSQL), Play Integrity à la création d'installation, plafonds de coût de l'assistant (par abonné et global par jour).

**Secrets applicatifs.** Clé Django, mots de passe des rôles et clé de signature CloudFront générés par Terraform ; clé de l'API Gemini et clé JSON du compte de service Google Play déposées à la main par le product owner (valeur provisoire `A_REMPLACER`, que l'API traite comme « non configuré » : 503 et alarme `ev-prod-google-not-configured`). Les rôles d'exécution ne lisent que nos secrets. Les tâches `api`, `migrate` et `jobs` n'ont **aucun rôle de tâche** (aucun droit AWS à l'exécution) ; seules les tâches de sauvegarde et de test de restauration en ont un, limité à notre bucket de sauvegardes et à notre clé.

## 7. Préproduction

`preprod_enabled = false` par défaut. Activée, elle crée dans la même pile un environnement séparé : cluster `ev-preprod`, base `eventide_preprod` et rôles `ev_preprod_*` (6 connexions au plus : 4 + 1 + 1), hôtes `api.preprod.<domaine>` et `preprod.<domaine>`, règles 420 et 421, Fargate Spot, service `api` allumé de 8 h à 20 h les jours ouvrés (heure de Bruxelles) et éteint sinon, clé KMS `alias/ev-preprod`, secrets `eventide/preprod/*`, contenu propre. Recommandation : l'activer quand des testeurs arrivent, pas avant ([coûts](../runbooks/couts-estimes.md)).

## 8. Risques

| Risque | Gravité | Parade |
|---|---|---|
| **Base mono-AZ partagée** : une panne arrête CINAF, JobMinutes, Candidature Express et Eventide ; restauration par CINAF (instantanés) ou par nous (`pg_dump` de la veille, RPO ≤ 24 h) | Élevée | Sauvegarde logique quotidienne, test de restauration ([runbook](../runbooks/premier-deploiement.md) § 12) ; passage à un compte dédié quand le chiffre d'affaires dépend de la disponibilité |
| **Voisin bruyant** dans les deux sens : un pic d'un autre produit ralentit nos requêtes, ou nos requêtes consomment le CPU et les crédits de l'instance | Moyenne | 14 connexions au plus, délais par rôle ; alarmes RDS facultatives (`rds_alarms_enabled`, lecture des seules métriques) ; requêtes courtes (compteurs par clé unique) |
| **Pas de WAF** : ni réputation IP, ni règles gérées, ni limite par IP en amont | Moyenne | Limites de débit dans l'application, Play Integrity, plafonds de coût ; à terme un compte dédié |
| Une évolution de l'infrastructure de CINAF supprime nos ajouts (règles intégrées dans son Terraform, recréation de l'ALB, de l'écouteur ou de la base) | Moyenne | Vérification demandée (§ 5) ; alarmes `ev-prod-api-unhealthy` et `ev-prod-api-5xx` ; plan Terraform régulier qui révèle les dérives |
| Montée de version majeure de l'instance par CINAF (17) | Faible | Le plan échoue (précondition « PostgreSQL 16 ») ; l'alarme `ev-prod-db-backup-missing` se déclenche ; mettre à jour l'image de `db_tools` |
| NAT unique en us-east-1a : une panne de zone coupe Google (Gemini, Play, Play Integrity) | Faible | Accepté (comme les autres invités) ; l'assistant retombe sur les règles locales du téléphone ; les achats sont revérifiés plus tard (`finalize-purchases`) |
| Politique TLS et délai d'inactivité de l'écouteur choisis par CINAF | Faible | Keep-alive de gunicorn calculé à partir du délai lu par Terraform (délai + 5 s, 75 s au moins) |
| Fournisseur OIDC GitHub géré par le Terraform de JobMinutes : sa suppression casse nos déploiements | Faible | Le recréer à l'identique ; dépendance à noter chez JobMinutes |
| Notre rôle de déploiement peut enregistrer une révision de définition de tâche dans **n'importe quelle famille** du compte (`ecs:RegisterTaskDefinition` sur `*`, comme Candidature Express) | Moyenne | Rôle assumable seulement par un job de `main` dans l'environnement GitHub `prod` ; `UpdateService`, `RunTask` et `PassRole` limités à nos ressources. À restreindre dès qu'une restriction par famille est vérifiée |
| Le même rôle lit les définitions de tâche des autres produits (`ecs:DescribeTaskDefinition` n'accepte que `*`), y compris d'éventuelles variables en clair | Moyenne | Limite connue d'ECS, acceptée ; correctif côté des autres produits (secrets dans Secrets Manager) |
| Chevauchement de déploiement (`deployment_maximum_percent = 200`) : jusqu'à 4 tâches `api` un court instant | Faible | Compté dans le budget de connexions (le plan échoue sinon) |
| Quotas du compte partagés (vCPU Fargate, 100 règles par écouteur, 25 certificats par ALB, distributions CloudFront) | Faible | 2 règles et 1 certificat par environnement, 2 tâches au plus |
| **Franchise gratuite de CloudFront partagée** (1 To et 10 millions de requêtes par mois pour tout le compte, très probablement consommée par CINAF, produit de streaming) | Moyenne | Coût du contenu calculé sans franchise ([coûts](../runbooks/couts-estimes.md)) ; budget `ev-prod-content-mensuel` et alarmes de volume ; formule CloudFront à prix fixe à étudier |
| Coûts mélangés avec ceux des autres produits | Faible | Étiquette `Project` active dans Billing ; budget et anomalies filtrés dessus |
| Compte sans CloudTrail ni GuardDuty (constat de Candidature Express le 9 octobre 2026, non revérifié) | Moyenne | Recommandé au product owner pour toute l'organisation |
| **Hébergement aux États-Unis** (RGPD) : la base, les sauvegardes, les journaux et l'origine du contenu sont à `us-east-1` ; Gemini est un service de Google hors de l'UE | Moyenne | Transfert couvert par l'*EU-US Data Privacy Framework* (adhésion d'AWS et de Google à vérifier) et, à défaut, par les clauses types ; **la politique de confidentialité le dit** (`backend/apps/web/templates/web/confidentialite.html`, § « Où sont vos données » : « États-Unis (Virginie du Nord) ») ; aucune phrase ni aucun son conservé ; offre payante de Gemini (conditions à revérifier avant l'ouverture). Le dossier recommandait une région européenne : écart assumé par la décision du product owner |

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
