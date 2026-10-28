# Eventide — consignes pour les agents IA

Application Android (Flutter, `app/`) de sons de nature sur de vrais paysages, réglable à la voix ; API Django 5.2 + DRF (`backend/`) ; infrastructure AWS en Terraform (`infra/`) ; CI GitHub Actions (`.github/`). Produit en français. Avant d'agir, lire [`docs/journal-de-developpement.md`](docs/journal-de-developpement.md) (état, décisions, questions ouvertes), puis selon la tâche [`docs/api/contrat-v1.md`](docs/api/contrat-v1.md), [`docs/app/architecture.md`](docs/app/architecture.md), [`docs/infra/hebergement-mutualise.md`](docs/infra/hebergement-mutualise.md).

## RÈGLE ABSOLUE — les autres plateformes restent intouchées et non influencées

Eventide est hébergée dans le compte AWS principal (`466494951409`, `us-east-1`) **à côté de trois plateformes en production : CINAF, JobMinutes et Candidature Express**. Elle emprunte certaines ressources de CINAF (VPC, sous-réseaux, NAT, ALB et son écouteur 443, instance PostgreSQL). Exigence du product owner (28 octobre 2026), **sans exception** :

**CINAF, JobMinutes et Candidature Express restent intouchées et ne doivent être influencées en aucun cas par ce que fait Eventide.**

Concrètement, pour tout agent, à chaque tâche qui touche l'infrastructure, la CI, le déploiement, la base de données ou un réglage AWS :

1. **Ne jamais modifier, remplacer, supprimer ni importer** une ressource de CINAF, JobMinutes ou Candidature Express. Elles ne sont que **référencées en lecture** (sources `data`). Un `terraform plan` qui montre un `change`, un `replace` ou un `destroy` sur une ressource qui n'est pas à Eventide est un **bogue bloquant**.
2. **Ne jamais lire leur contenu** : ni leurs bases, ni leurs secrets, ni leurs journaux, ni leurs objets S3, ni leurs définitions de tâches.
3. **Aucun réglage à l'échelle du compte ou de la région** (GuardDuty, Security Hub, Config, blocage d'accès public S3 du compte, réglages par défaut ECS/EC2/EBS, politique de mots de passe IAM, fournisseur OIDC, politiques de ressources CloudWatch Logs…) : la liste est contrôlée par [`.github/scripts/check-shared-account-resources.sh`](.github/scripts/check-shared-account-resources.sh), à étendre, jamais à contourner.
4. **Seuls quatre types d'ajouts** sont posés sur des ressources de CINAF, tous réversibles et décrits dans l'ADR : nos règles d'écoute de l'ALB (priorités 400–409, préproduction 420–429, limitées à **nos** noms d'hôte), notre certificat ajouté à l'écouteur (choisi par SNI pour nos seuls noms), une règle d'entrée 5432 autonome sur le groupe de sécurité de la base, nos rôles et bases sur l'instance PostgreSQL. **Tout nouveau point de contact exige un ADR et l'accord du product owner.**
5. **Ne pas peser sur leurs ressources partagées** : plafond de connexions et délais par rôle sur la base partagée, petites tâches, limites de débit, alarmes sur la charge de l'instance ; tout ce qui pourrait ralentir, saturer ou renchérir CINAF, JobMinutes ou Candidature Express doit être signalé avant d'être fait.
6. **Noms et étiquettes propres** : préfixes `ev-` / `eventide`, étiquette `Project = eventide` ; aucune collision de nom, de priorité d'écoute ou de famille de tâches avec les autres plateformes (Candidature Express utilise les priorités 300–329 et le préfixe `ce-`).
7. **Aucun appel AWS par un agent** : ni `terraform plan/apply`, ni CLI, ni SDK contre le compte. Tests Terraform avec fournisseurs simulés et **sans identifiants** (`env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN …`). Jamais de `terraform apply` sans l'accord explicite du product owner, donné pour chaque `apply` après relecture du plan.
8. **Transmettre cette règle** : tout agent qui délègue un travail touchant ces sujets recopie cette section dans la consigne du sous-agent.

## Autres règles

- **Contrat d'abord** : une forme d'API qui change s'écrit dans `docs/api/contrat-v1.md` avant le code. Le catalogue fermé est `app/assets/catalog.json` (une seule source).
- **Git** : un agent délégué ne touche jamais à git en écriture ; l'orchestrateur garde git et la vérification finale.
- **Secrets** : rien dans git (`.env`, `*.tfvars`, `key.properties`, clés, comptes de service).
- Code et consignes aux sous-agents en anglais ; textes de l'app et documentation en français.
- **Fin de session** : mettre à jour le journal (état, décisions, prochaines étapes).
