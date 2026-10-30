# Coûts estimés — Eventide (hébergement mutualisé, us-east-1)

> **Estimation au 28 octobre 2026 (mise à jour le 29 octobre 2026 : assistant vocal et Gemini retirés), pas une facture.** Montants mensuels en **USD hors taxes** (mois de 730 heures), région AWS **`us-east-1`**, configuration lue dans [`infra/terraform/envs/shared-prod/main.tf`](../../infra/terraform/envs/shared-prod/main.tf) et ses modules ([ADR](../infra/hebergement-mutualise.md)). **Aucun prix n'a été revérifié le 28 octobre 2026** : chaque prix porte sa source et la date à laquelle elle a été relevée (§ 7) ; « non vérifié » signale un prix que personne n'a confirmé sur une page officielle. Rien n'est encore déployé : à comparer aux dépenses réelles une semaine après la mise en service.
>
> Pour qui : le product owner.

## 1. En bref

| Situation | USD / mois |
|---|---|
| **Phase 1** : déployé sans domaine (base, secrets, alarmes, contenu, tâches planifiées ; pas de service `api`) | **≈ 8** |
| **Phase 2, lancement** : 1 tâche `api` en permanence, peu de trafic | **≈ 18**, plus le contenu (§ 4) |
| Phase 2, plafond : 2 tâches `api` en permanence (maximum de l'autoscaling, borné par le budget de connexions PostgreSQL) | **≈ 29**, plus le contenu |
| Préproduction activée (§ 3) | **+ ≈ 8** |

Le poste variable est **la diffusion du contenu** (CloudFront : ≈ 1,3 USD pour 1 000 sessions gratuites à froid, ≈ 128 USD pour 100 000). Plus aucun coût de modèle d'IA : l'assistant vocal est retiré (29 octobre 2026). Repère : un abonnement annuel rapporte ≈ 3,51 € nets par mois (dossier d'analyse) ; les coûts fixes du lancement sont couverts à partir de ≈ 5 abonnés.

Ce qui n'est pas payé, grâce à l'hébergement mutualisé : VPC, NAT, ALB, instance PostgreSQL, WAF, cache Redis/Valkey (aucun : les compteurs sont dans PostgreSQL). L'ALB, la NAT et la base restent payés par le compte (CINAF) ; notre part marginale est chiffrée ci-dessous.

## 2. Production

Dimensionnement (`envs/shared-prod/main.tf`) : tâche `api` Fargate **ARM64, 0,25 vCPU, 0,5 Go**, 1 à 2 tâches (suivi de cible CPU, mémoire et requêtes), 1 worker gunicorn × 8 threads ; tâches planifiées en **Fargate Spot** (0,25 vCPU, 0,5 Go) : `finalize-purchases` toutes les heures, `purge-expired` et `db-backup` une fois par jour ; journaux 30 jours, sauvegardes 35 jours.

Prix d'une tâche `api` : 0,25 × 0,03238 + 0,5 × 0,00356 = **0,009875 USD/h**, soit **7,21 USD pour 730 h** [FG-USE1].

| Poste | Hypothèse | Prix unitaire [source] | Phase 1 | Lancement | Plafond |
|---|---|---|---|---|---|
| Fargate ARM — `api` | Phase 1 : pas de service ; lancement : 1 tâche (+ quelques heures à 2 tâches) ; plafond : 2 tâches en permanence | 0,03238 /vCPU-h, 0,00356 /Go-h [FG-USE1] | 0 | 7,5 | 14,4 |
| Tâches planifiées et ponctuelles (Spot) | ≈ 13 h de tâche par mois (24 exécutions par jour d'environ 1 minute, plus purge et sauvegarde), migrations | Spot ≈ -65 % (non vérifié) [CE-COUTS] | < 0,1 | < 0,1 | 0,2 |
| Secrets Manager | 7 secrets : `django-secret-key`, `db-app`, `db-migrator`, `db-backup`, `google-play-service-account`, `cloudfront-private-key`, `admin-emails` (tableau de bord, § 4 bis) (le secret temporaire d'amorçage vit quelques minutes) | 0,40 /secret [CE-COUTS] | 2,8 | 2,8 | 2,8 |
| KMS | `alias/ev-prod` + `alias/eventide-tfstate`, requêtes | 1 /clé [CE-COUTS] | 2,0 | 2,1 | 2,2 |
| CloudWatch — alarmes | Phase 1 : 16 (4 événements applicatifs, 2 volumes de journaux, sauvegarde manquante, 4 contenu, 5 sur la charge de l'instance partagée : CPU, connexions, mémoire, disque, crédits) ; phase 2 : 21 (+ 5xx, latence p95, cibles en échec, CPU et mémoire du service) ; la franchise de 10 alarmes du compte est supposée consommée par les autres produits | 0,10 /alarme [CE-COUTS] | 1,6 | 2,1 | 2,1 |
| CloudWatch — métriques issues des journaux | 5 métriques (4 événements applicatifs, sauvegarde envoyée) | 0,30 /métrique [CE-COUTS] | 1,5 | 1,5 | 1,5 |
| CloudWatch — journaux | 0,1 / 1 / 3 Go ingérés, 30 jours (JSON sans corps de requête) | 0,50 /Go [CE-COUTS] | 0,1 | 0,5 | 1,5 |
| ALB partagé — part marginale | LCU de nos requêtes ; 2 règles de plus à évaluer | 0,008 /LCU-h [CE-COUTS] | 0 | 0,5 | 2 |
| NAT partagée — données traitées | Appels à Google (Play, Play Integrity), journaux, API AWS ; **images de nos tâches** : chaque tâche Fargate retélécharge son image (≈ 0,1 Go), soit ≈ 26 tâches par jour (24 `finalize-purchases`, `purge-expired`, `db-backup` ≈ 0,25 Go) ≈ 80 Go/mois. Sans point de terminaison S3 dans le VPC de CINAF (à vérifier, § 4 du runbook), elles passent par la NAT : ≈ 3,5 à 4 USD/mois. **Facturé sur la NAT de CINAF** : invisible dans nos budgets ([ADR § 11](../infra/hebergement-mutualise.md#11-non-influence-sur-cinaf-jobminutes-et-candidature-express)) | 0,045 /Go [CE-COUTS] | 0,1 à 4 | 0,3 à 4,5 | 1 à 5 |
| Transfert sortant de l'API vers Internet | Réponses JSON et pages web : 1 à 10 Go (franchise de 100 Go supposée consommée par les autres produits) | 0,09 /Go [CE-COUTS] | 0 | 0,2 | 0,9 |
| ECR, S3 (sauvegardes, contenu stocké, état Terraform) | Images ≈ 0,1 Go chacune, 10 gardées ; contenu < 0,2 Go ; sauvegardes de quelques Mo | 0,10 /Go ECR [CE-COUTS] ; S3 ≈ 0,023 /Go (non vérifié) | 0,2 | 0,2 | 0,3 |
| Route 53 | Notre zone (créée à l'achat du domaine) ; requêtes vers les alias | 0,50 /zone [CE-COUTS] | 0 | 0,5 | 0,6 |
| Budgets, détection d'anomalies, EventBridge Scheduler, ACM, OAC et adresses signées CloudFront | — | gratuits [CE-COUTS], [DOSSIER] | 0 | 0 | 0 |
| Registraire des définitions de tâche (Lambda `ev-prod-task-registrar`, ARM64, 128 Mo) | Quelques appels par déploiement, hors VPC (aucun trafic par la NAT) | ≈ 0 (non vérifié) | 0 | 0 | 0 |
| **Total AWS hors contenu diffusé** | Fourchette basse de la NAT (point de terminaison S3 présent) ; jusqu'à ≈ +4 USD sinon, payés par CINAF (plus le tableau de bord, § 4 bis) | | **≈ 8,4** | **≈ 18,3** | **≈ 29,5** |

« Plafond » est aussi le **plafond de dépense fixe** en cas d'attaque ou de boucle : l'autoscaling ne dépasse pas 2 tâches (le plan Terraform échoue si le budget de connexions pouvait être dépassé). Le poste variable (contenu) reste borné par les garde-fous du § 4.

**Budgets posés par Terraform** (filtrés sur `Project = eventide`, alertes seulement, AWS ne coupe rien) : `eventide-mensuel` **60 USD** (50, 80 et 100 % du réel, 100 % de la prévision), `ev-prod-content-mensuel` **30 USD** (CloudFront et S3), moniteur d'anomalies (seuil 10 USD). Ils ne voient rien tant que l'étiquette `Project` n'est pas active dans Billing (déjà active pour les autres produits, à vérifier).

**Coûts cachés sur l'infrastructure partagée**, non facturés à part mais réels, **portés par les ressources de CINAF** (donc invisibles dans `eventide-mensuel`) : données traitées par la NAT (ci-dessus, jusqu'à ≈ 4 USD/mois), unités de capacité de l'ALB (< 1 USD/mois au lancement), stockage de notre base sur l'instance et dans ses instantanés (quelques centaines de Mo la première année), crédits CPU de l'instance si nos requêtes la font dépasser sa ligne de base. Détail et parades : [ADR § 11](../infra/hebergement-mutualise.md#11-non-influence-sur-cinaf-jobminutes-et-candidature-express).

## 3. Préproduction (facultative, `preprod_enabled`)

| Poste | Hypothèse | USD / mois |
|---|---|---|
| Fargate Spot ARM | 1 tâche `api` (0,25 vCPU, 0,5 Go), 8 h-20 h les jours ouvrés (≈ 260 h/mois), Spot ≈ -65 % (non vérifié) | ≈ 1 |
| Secrets Manager, KMS | 7 secrets (dont `admin-emails`), 1 clé | 3,8 |
| CloudWatch (alarmes, métriques, journaux 14 jours) | 11 à 16 alarmes, 5 métriques | ≈ 2,5 à 3 |
| ECR, S3, CloudFront (contenu de test), divers | | ≈ 0,5 |
| **Total préproduction** | | **≈ 8** |

Désactivée par défaut : aucun coût.

## 4. Contenu : CloudFront et S3

Le contenu (boucles sonores, musiques, photos) est servi par **notre** distribution CloudFront depuis un bucket S3 privé (`PriceClass_100` : Amérique du Nord, Europe, Israël). Le gratuit exige une connexion : chaque session à froid télécharge le mix.

Hypothèses du dossier d'analyse : boucle de 3 minutes en Opus à 96 kbit/s ≈ 2,2 Mo ; mix de 6 couches ≈ 13 Mo + image ≈ 1,5 Mo, soit **≈ 15 Mo par session à froid** (moins quand le téléphone a déjà les fichiers en cache) ; ≈ 7 requêtes par session. Prix : **0,085 USD/Go** (10 premiers To) et **0,012 USD pour 10 000 requêtes HTTPS** [DOSSIER], [AWS-CF] ; transfert de S3 vers CloudFront gratuit.

**La franchise gratuite de CloudFront (1 To et 10 millions de requêtes par mois) est celle du compte**, très probablement consommée par CINAF (produit de streaming ; non vérifiable sans lire ses ressources). Le tableau la suppose donc épuisée ; la colonne de droite la suppose libre.

| Sessions à froid par mois | Volume | Sans franchise | Avec la franchise du compte |
|---|---|---|---|
| 1 000 | 15 Go | ≈ 1,3 USD | ≈ 0 |
| 10 000 | 150 Go | ≈ 12,8 USD | ≈ 0 |
| 100 000 | 1,5 To | ≈ 128 USD | ≈ 43 USD |

- **Formule CloudFront à prix fixe** [DOSSIER] : Pro à 15 USD/mois (10 millions de requêtes, 50 To, sans facture de dépassement) ; moins chère que le paiement à l'usage au-delà de ≈ 180 Go par mois sans franchise (≈ 12 000 sessions à froid). À étudier avant d'atteindre ce volume (rattachement à notre seule distribution à vérifier ; non prévu dans Terraform).
- **Garde-fous** : budget `ev-prod-content-mensuel` (30 USD) ; alarmes `ev-prod-content-requests-day` (> 200 000 requêtes par jour) et `ev-prod-content-bytes-day` (> 30 Go par jour), `-5xx`, `-4xx`. Les adresses signées expirent après 1 heure et l'API limite les demandes d'adresses (120 par heure et par installation).
- **Stockage S3** : < 0,2 Go pour le catalogue actuel (12 paysages, 10 sons, 8 musiques) : < 0,01 USD/mois.

### 4 bis. Tableau de bord et traitement des médias (30 octobre 2026)

Hypothèse : 20 fichiers envoyés par mois (300 Mo au plus), une tâche `ev-prod-media` de 1 vCPU / 2 Go pendant 5 à 15 minutes chacune ([ADR § 12.4](../infra/hebergement-mutualise.md#124-ressources-partagées--analyse-chiffrée), estimations non mesurées).

| Poste | Hypothèse | USD / mois |
|---|---|---|
| Fargate ARM à la demande (tâche `media`) | 0,03238 + 2 × 0,00356 ≈ 0,04 USD/h [FG-USE1], ≤ 5 h | ≈ 0,2 |
| Secrets Manager | +1 secret (`admin-emails`) par environnement : 7 secrets en production | +0,4 |
| S3 (sources dans `uploads/`, effacées après 7 jours ; fichiers traités) | ≈ 1,6 Go-mois en moyenne ; l'envoi vers S3 est gratuit | < 0,05 |
| **NAT de CINAF** : trafic de la tâche `media` | Source, fichiers traités et image : ≤ 10 Go à 0,045 USD/Go [CE-COUTS] | ≤ 0,45 (payé par CINAF) |
| **NAT de CINAF** : image plus lourde de ffmpeg pour **toutes** les tâches | ≈ 770 téléchargements de l'image par mois ; +0,1 Go chacun avec le paquet Debian (≈ +0,03 Go avec un ffmpeg réduit) | ≈ +3,5 (≈ +1) (payé par CINAF) |
| ALB de CINAF | Pages du tableau de bord seulement ; les fichiers passent directement du navigateur à S3 | < 0,01 |

Soit ≈ 0,6 USD/mois sur nos budgets et ≈ 1,5 à 4 USD/mois sur la NAT de CINAF, à leur signaler (règle 5).

## 5. Services Google (hors AWS)

L'assistant vocal et son modèle (Gemini) sont retirés depuis le 29 octobre 2026 : plus aucun coût d'IA.

- API Google Play Developer, Play Integrity (quota quotidien gratuit de l'offre standard, à vérifier), Pub/Sub pour les notifications Google Play (volume négligeable, dans la franchise gratuite : non vérifié).

## 6. Hors AWS et hors Google Cloud

| Poste | Montant | Source |
|---|---|---|
| Commission Google Play | 15 % du prix hors taxe (abonnements et achats) | [DOSSIER] |
| Compte de développeur Google Play | déjà payé ou 25 USD une fois (non vérifié) | — |
| Nom de domaine | à chiffrer quand le nom est choisi (marque « Eventide » en cours de vérification) | — |
| GitHub Actions | runners `ubuntu-24.04-arm` pour l'image ARM64 : décomptés des minutes incluses du plan GitHub (non chiffré) | [CE-COUTS] |

## 7. Sources

| Code | Source | Date du relevé |
|---|---|---|
| [FG-USE1] | AWS Fargate Pricing, <https://aws.amazon.com/fargate/pricing/> (Linux/ARM, US East (N. Virginia) : 0,0000089944 USD par vCPU-seconde, 0,0000009889 USD par Go-seconde), relevé par Candidature Express | 2026-10-09, non revérifié le 2026-10-28 |
| [CE-COUTS] | Candidature Express, `docs/runbooks/couts-estimes.md` (hébergement mutualisé, us-east-1) : prix lus dans la liste de prix publique d'AWS, **non revérifiés par Candidature Express le 2026-10-09** (Secrets Manager, KMS, CloudWatch, ELB, NAT, transfert, ECR, Route 53, Spot, gratuité des budgets) | 2026-10-09, non revérifié |
| [DOSSIER] | Dossier d'analyse d'Eventide, sections « Ce que coûte le gratuit », « Coûts AWS et garde-fous », prix de vente | Prix AWS consultés le 2026-10-28 par l'auteur du dossier, non revérifiés ici |
| [AWS-CF] | <https://aws.amazon.com/cloudfront/pricing/>, <https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html> (cités par le dossier) | 2026-10-28 (dossier) |
| Code | `infra/terraform/envs/shared-prod/main.tf`, `modules/*` | 2026-10-29 |

Les montants peuvent être recalculés dans l'AWS Pricing Calculator (<https://calculator.aws/>).
