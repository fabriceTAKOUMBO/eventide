# Coûts estimés — Eventide (hébergement mutualisé, us-east-1)

> **Estimation au 28 octobre 2026, pas une facture.** Montants mensuels en **USD hors taxes** (mois de 730 heures), région AWS **`us-east-1`**, configuration lue dans [`infra/terraform/envs/shared-prod/main.tf`](../../infra/terraform/envs/shared-prod/main.tf) et ses modules ([ADR](../infra/hebergement-mutualise.md)). **Aucun prix n'a été revérifié le 28 octobre 2026** : chaque prix porte sa source et la date à laquelle elle a été relevée (§ 7) ; « non vérifié » signale un prix que personne n'a confirmé sur une page officielle. Rien n'est encore déployé : à comparer aux dépenses réelles une semaine après la mise en service.
>
> Pour qui : le product owner.

## 1. En bref

| Situation | USD / mois |
|---|---|
| **Phase 1** : déployé sans domaine (base, secrets, alarmes, contenu, tâches planifiées ; pas de service `api`) | **≈ 9** |
| **Phase 2, lancement** : 1 tâche `api` en permanence, peu de trafic | **≈ 19**, plus le contenu (§ 4) et Gemini (§ 5) |
| Phase 2, plafond : 2 tâches `api` en permanence (maximum de l'autoscaling, borné par le budget de connexions PostgreSQL) | **≈ 30**, plus le contenu et Gemini |
| Préproduction activée (§ 3) | **+ ≈ 9** |

Les deux postes variables sont **la diffusion du contenu** (CloudFront : ≈ 1,3 USD pour 1 000 sessions gratuites à froid, ≈ 128 USD pour 100 000) et **Gemini** (≈ 0,0002 USD par phrase envoyée au modèle, plafonné à 2 € par abonné et par mois et à 20 € par jour pour tout le service). Repère : un abonnement annuel rapporte ≈ 3,51 € nets par mois (dossier d'analyse) ; les coûts fixes du lancement sont couverts à partir de ≈ 5 abonnés.

Ce qui n'est pas payé, grâce à l'hébergement mutualisé : VPC, NAT, ALB, instance PostgreSQL, WAF, cache Redis/Valkey (aucun : les compteurs sont dans PostgreSQL). L'ALB, la NAT et la base restent payés par le compte (CINAF) ; notre part marginale est chiffrée ci-dessous.

## 2. Production

Dimensionnement (`envs/shared-prod/main.tf`) : tâche `api` Fargate **ARM64, 0,25 vCPU, 0,5 Go**, 1 à 2 tâches (suivi de cible CPU, mémoire et requêtes), 1 worker gunicorn × 8 threads ; tâches planifiées en **Fargate Spot** (0,25 vCPU, 0,5 Go) : `finalize-purchases` toutes les heures, `purge-expired` et `db-backup` une fois par jour ; journaux 30 jours, sauvegardes 35 jours.

Prix d'une tâche `api` : 0,25 × 0,03238 + 0,5 × 0,00356 = **0,009875 USD/h**, soit **7,21 USD pour 730 h** [FG-USE1].

| Poste | Hypothèse | Prix unitaire [source] | Phase 1 | Lancement | Plafond |
|---|---|---|---|---|---|
| Fargate ARM — `api` | Phase 1 : pas de service ; lancement : 1 tâche (+ quelques heures à 2 tâches) ; plafond : 2 tâches en permanence | 0,03238 /vCPU-h, 0,00356 /Go-h [FG-USE1] | 0 | 7,5 | 14,4 |
| Tâches planifiées et ponctuelles (Spot) | ≈ 13 h de tâche par mois (24 exécutions par jour d'environ 1 minute, plus purge et sauvegarde), migrations | Spot ≈ -65 % (non vérifié) [CE-COUTS] | < 0,1 | < 0,1 | 0,2 |
| Secrets Manager | 7 secrets : `django-secret-key`, `db-app`, `db-migrator`, `db-backup`, `gemini-api-key`, `google-play-service-account`, `cloudfront-private-key` (le secret temporaire d'amorçage vit quelques minutes) | 0,40 /secret [CE-COUTS] | 2,8 | 2,8 | 2,8 |
| KMS | `alias/ev-prod` + `alias/eventide-tfstate`, requêtes | 1 /clé [CE-COUTS] | 2,0 | 2,1 | 2,2 |
| CloudWatch — alarmes | Phase 1 : 13 (6 événements applicatifs, 2 volumes de journaux, sauvegarde manquante, 4 contenu) ; phase 2 : 18 (+ 5xx, latence p95, cibles en échec, CPU et mémoire du service) ; la franchise de 10 alarmes du compte est supposée consommée par les autres produits | 0,10 /alarme [CE-COUTS] | 1,3 | 1,8 | 1,8 |
| CloudWatch — métriques issues des journaux | 7 métriques (6 événements applicatifs, sauvegarde envoyée) | 0,30 /métrique [CE-COUTS] | 2,1 | 2,1 | 2,1 |
| CloudWatch — journaux | 0,1 / 1 / 3 Go ingérés, 30 jours (JSON sans phrase ni corps de requête) | 0,50 /Go [CE-COUTS] | 0,1 | 0,5 | 1,5 |
| ALB partagé — part marginale | LCU de nos requêtes ; 2 règles de plus à évaluer | 0,008 /LCU-h [CE-COUTS] | 0 | 0,5 | 2 |
| NAT partagée — données traitées | Appels à Google (Gemini, Play, Play Integrity), journaux, API AWS, images ECR (couches par le point de terminaison S3 gratuit de CINAF, à confirmer) | 0,045 /Go [CE-COUTS] | < 0,1 | 0,3 | 1 |
| Transfert sortant de l'API vers Internet | Réponses JSON et pages web : 1 à 10 Go (franchise de 100 Go supposée consommée par les autres produits) | 0,09 /Go [CE-COUTS] | 0 | 0,2 | 0,9 |
| ECR, S3 (sauvegardes, contenu stocké, état Terraform) | Images ≈ 0,1 Go chacune, 10 gardées ; contenu < 0,2 Go ; sauvegardes de quelques Mo | 0,10 /Go ECR [CE-COUTS] ; S3 ≈ 0,023 /Go (non vérifié) | 0,2 | 0,2 | 0,3 |
| Route 53 | Notre zone (créée à l'achat du domaine) ; requêtes vers les alias | 0,50 /zone [CE-COUTS] | 0 | 0,5 | 0,6 |
| Budgets, détection d'anomalies, EventBridge Scheduler, ACM, OAC et adresses signées CloudFront | — | gratuits [CE-COUTS], [DOSSIER] | 0 | 0 | 0 |
| **Total AWS hors contenu diffusé** | | | **≈ 8,7** | **≈ 18,6** | **≈ 29,8** |

« Plafond » est aussi le **plafond de dépense fixe** en cas d'attaque ou de boucle : l'autoscaling ne dépasse pas 2 tâches (le plan Terraform échoue si le budget de connexions pouvait être dépassé). Les postes variables restent bornés par les plafonds du § 4 et du § 5.

**Budgets posés par Terraform** (filtrés sur `Project = eventide`, alertes seulement, AWS ne coupe rien) : `eventide-mensuel` **60 USD** (50, 80 et 100 % du réel, 100 % de la prévision), `ev-prod-content-mensuel` **30 USD** (CloudFront et S3), moniteur d'anomalies (seuil 10 USD). Ils ne voient rien tant que l'étiquette `Project` n'est pas active dans Billing (déjà active pour les autres produits, à vérifier).

**Coûts cachés sur l'infrastructure partagée**, non facturés à part mais réels : stockage de notre base sur l'instance (quelques centaines de Mo la première année), crédits CPU de l'instance de CINAF si nos requêtes la font dépasser sa ligne de base.

## 3. Préproduction (facultative, `preprod_enabled`)

| Poste | Hypothèse | USD / mois |
|---|---|---|
| Fargate Spot ARM | 1 tâche `api` (0,25 vCPU, 0,5 Go), 8 h-20 h les jours ouvrés (≈ 260 h/mois), Spot ≈ -65 % (non vérifié) | ≈ 1 |
| Secrets Manager, KMS | 7 secrets, 1 clé | 3,8 |
| CloudWatch (alarmes, métriques, journaux 14 jours) | 13 à 18 alarmes, 7 métriques | ≈ 3,5 à 4 |
| ECR, S3, CloudFront (contenu de test), divers | | ≈ 0,5 |
| **Total préproduction** | | **≈ 9** |

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

## 5. Assistant vocal : Gemini (facturé par Google, hors AWS)

Prix de **Gemini 2.5 Flash-Lite** : **0,10 USD par million de jetons en entrée, 0,40 USD en sortie** (page officielle de Google consultée le 2026-10-28 par l'auteur du dossier [GEM] ; non revérifié ici). Modèle choisi par configuration (`voice.model`) ; la table de prix de l'API (`VOICE_PRICE_TABLE`) doit être mise à jour en même temps.

Taille d'une demande (estimation, **aucun appel réel n'a été fait**) : consigne et catalogue ≈ 4 300 caractères, schéma de réponse ≈ 1 600, phrase et état du mix ≈ 200, soit ≈ 6 100 caractères, **≈ 1 750 jetons en entrée** (à raison de ≈ 3,5 caractères par jeton, non mesuré) et **≈ 150 en sortie** (réflexion désactivée : `thinkingBudget = 0`). Coût : 1 750 × 0,10 / 10⁶ + 150 × 0,40 / 10⁶ ≈ **0,00024 USD par phrase** (le dossier, avec 1 200 jetons, trouve 0,00018 USD). L'API calcule le coût réel de chaque appel à partir des jetons comptés par Google (`usageMetadata`) : ce chiffre se lira dans `GET /v1/account/export` et dans les journaux (`voice_answered`, sans la phrase).

| Usage | Coût |
|---|---|
| Essai gratuit : 3 phrases à vie par appareil | ≈ 0,0007 USD par nouvelle installation |
| Abonné : 30 / 100 / 300 phrases envoyées au modèle par mois | ≈ 0,007 / 0,024 / 0,07 USD par abonné |
| 1 000 abonnés à 100 phrases | ≈ 24 USD/mois |

- **Plafonds tenus par l'API** (mises à jour conditionnelles dans PostgreSQL, avant chaque appel) : **2 € par abonné et par mois** (`voice.monthly_cap_eur`, ≈ 8 900 phrases au coût estimé) et **20 € par jour pour tout le service** (`voice.global_daily_cap_eur`), soit **≈ 620 € par mois au pire** (≈ 670 USD au taux de 0,93 € par USD utilisé par l'API, `voice.usd_eur_rate`, à revoir : non vérifié). Au-delà, l'API répond `503 model_unavailable` et le téléphone retombe sur ses règles locales. **À l'ouverture, envisager un plafond global plus bas** (par exemple 5 € par jour) puis le relever avec l'usage observé.
- Les phrases comprises par les règles du téléphone ne sont pas envoyées au modèle (seulement comptées, sauf pour les abonnés) : elles ne coûtent rien.
- **Ces dépenses ne sont pas dans les budgets AWS** : poser un budget et des alertes de facturation sur le projet Google Cloud de la clé Gemini.
- Autres services Google utilisés : API Google Play Developer, Play Integrity (quota quotidien gratuit de l'offre standard, à vérifier), Pub/Sub pour les notifications Google Play (volume négligeable, dans la franchise gratuite : non vérifié).

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
| [GEM] | <https://ai.google.dev/gemini-api/docs/pricing> (cité par le dossier) | 2026-10-28 (dossier) |
| Code | `infra/terraform/envs/shared-prod/main.tf`, `modules/*` ; `backend/apps/voice/prompt.py` (taille de la consigne mesurée en caractères) | 2026-10-28 |

Les montants peuvent être recalculés dans l'AWS Pricing Calculator (<https://calculator.aws/>).
