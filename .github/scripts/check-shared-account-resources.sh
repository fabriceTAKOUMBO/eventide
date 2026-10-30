#!/usr/bin/env bash
# Garde des ressources à l'échelle du compte (hébergement mutualisé : compte AWS partagé avec
# CINAF, JobMinutes et Candidature Express, docs/infra/hebergement-mutualise.md). Reprise de
# Candidature Express. Échoue si le code Terraform :
#   - déclare un type de ressource qui agit sur TOUT le compte ou toute une région (détecteur
#     et organisation GuardDuty, Security Hub, AWS Config, blocage d'accès public S3 du compte,
#     politique de mots de passe IAM, réglages par défaut EC2/EBS/ECS, Organizations...) :
#     l'activer ou le détruire changerait aussi les autres applications du compte ;
#   - appelle un module non local (registre, git...), dont le contenu échapperait au contrôle.
# Exception : aws_guardduty_malware_protection_plan (ne viserait qu'un bucket à nous). Aucune
# exception pour aws_iam_openid_connect_provider : Eventide ne fait que LIRE le fournisseur OIDC
# GitHub existant (source de données), il ne le crée jamais.
# Les fichiers .tf.json sont analysés aussi.
#
# Recherche textuelle volontairement simple, sur tous les .tf (compte partagé et compte dédié :
# mêmes modules). Un vrai besoin dans le compte dédié se règle en ajustant cette liste par une
# pull request relue, jamais en contournant le contrôle.
#
# Usage : check-shared-account-resources.sh [dossier Terraform] (défaut : infra/terraform)
set -euo pipefail

root="${1:-infra/terraform}"
if [ ! -d "$root" ]; then
  echo "::error::Dossier Terraform introuvable : $root"
  exit 1
fi

forbidden='aws_guardduty_[a-z0-9_]+|aws_securityhub_[a-z0-9_]+|aws_config_[a-z0-9_]+'
forbidden+='|aws_s3_account_public_access_block|aws_s3control_storage_lens_configuration'
forbidden+='|aws_iam_account_password_policy|aws_iam_account_alias|aws_iam_service_linked_role'
forbidden+='|aws_organizations_[a-z0-9_]+|aws_account_[a-z0-9_]+|aws_ram_sharing_with_organization'
forbidden+='|aws_ebs_encryption_by_default|aws_ebs_default_kms_key|aws_ebs_snapshot_block_public_access'
forbidden+='|aws_ec2_image_block_public_access|aws_ec2_serial_console_access|aws_ec2_instance_metadata_defaults'
forbidden+='|aws_vpc_block_public_access_options|aws_default_vpc|aws_default_subnet|aws_default_vpc_dhcp_options'
forbidden+='|aws_ecs_account_setting_default|aws_api_gateway_account|aws_xray_encryption_config'
forbidden+='|aws_cloudwatch_log_account_policy|aws_macie2_[a-z0-9_]+|aws_inspector2_[a-z0-9_]+'
forbidden+='|aws_detective_[a-z0-9_]+|aws_securitylake_[a-z0-9_]+|aws_fms_[a-z0-9_]+'
forbidden+='|aws_shield_subscription|aws_shield_proactive_engagement'
forbidden+='|aws_sesv2_account_[a-z0-9_]+|aws_ses_active_receipt_rule_set'
# Réglages d'ensemble du compte ou de la région (revue de sécurité L7).
forbidden+='|aws_ecr_registry_scanning_configuration|aws_ecr_registry_policy|aws_ecr_replication_configuration'
forbidden+='|aws_ecr_pull_through_cache_rule|aws_sns_sms_preferences|aws_iam_openid_connect_provider'
forbidden+='|aws_ssm_service_setting|aws_iam_security_token_service_preferences|aws_cloudwatch_log_resource_policy'
# Account- or region-wide settings found in the non-influence review of 28 October 2026.
forbidden+='|aws_ecr_account_setting|aws_ssm_default_patch_baseline|aws_ce_cost_allocation_tag|aws_resourceexplorer2_index'
forbidden+='|aws_backup_global_settings|aws_backup_region_settings|aws_accessanalyzer_analyzer|aws_auditmanager_account_registration'
forbidden+='|aws_emr_block_public_access_configuration|aws_glue_data_catalog_encryption_settings|aws_glue_resource_policy'
forbidden+='|aws_lakeformation_data_lake_settings|aws_cloudwatch_event_bus_policy|aws_cloudwatch_event_permission'
forbidden+='|aws_cloudwatch_event_archive|aws_cloudtrail|aws_iam_saml_provider|aws_s3control_[a-z0-9_]+|aws_default_[a-z0-9_]+'
# Dashboard review (30 October 2026): aws_iam_policy_attachment manages EVERY attachment of a
# policy across the account (exclusive): it would detach that policy from the roles of the other
# platforms. Use aws_iam_role_policy (inline, on our roles) instead.
forbidden+='|aws_iam_policy_attachment'
# Shared infrastructure of CINAF (and of the other guests): never managed by Eventide, only read
# by data sources. Includes what would change the shared VPC's routing or DNS for everyone (VPC
# endpoints, private DNS namespaces and zones, resolver rules, DHCP options), legacy security
# group rules (can target any group), WAF associations (would filter the shared ALB) and log
# subscriptions or event archives (would read the other platforms' logs or events).
forbidden+='|aws_lb|aws_alb|aws_elb|aws_lb_listener|aws_alb_listener|aws_alb_listener_rule|aws_alb_listener_certificate'
forbidden+='|aws_lb_target_group_attachment|aws_alb_target_group_attachment|aws_lb_cookie_stickiness_policy|aws_lb_ssl_negotiation_policy'
forbidden+='|aws_wafv2_web_acl_association|aws_waf_[a-z0-9_]+|aws_wafregional_[a-z0-9_]+|aws_shield_protection[a-z0-9_]*'
forbidden+='|aws_db_[a-z0-9_]+|aws_rds_[a-z0-9_]+|aws_vpc|aws_subnet|aws_nat_gateway|aws_internet_gateway'
forbidden+='|aws_egress_only_internet_gateway|aws_eip_association|aws_route|aws_route_table|aws_route_table_association'
forbidden+='|aws_main_route_table_association|aws_network_acl|aws_network_acl_rule|aws_network_acl_association'
forbidden+='|aws_security_group_rule|aws_vpc_endpoint|aws_vpc_endpoint_[a-z0-9_]+|aws_vpc_ipv4_cidr_block_association'
forbidden+='|aws_vpc_ipv6_cidr_block_association|aws_vpc_dhcp_options|aws_vpc_dhcp_options_association|aws_flow_log'
forbidden+='|aws_ec2_traffic_mirror_[a-z0-9_]+|aws_ec2_tag|aws_route53_zone|aws_route53_zone_association'
forbidden+='|aws_route53_vpc_association_authorization|aws_route53_resolver_[a-z0-9_]+|aws_service_discovery_private_dns_namespace'
forbidden+='|aws_cloudwatch_log_subscription_filter'
# Objects placed ON a shared resource: only the contact points of the ADR, only where they are
# declared (see allowed_at below).
forbidden+='|aws_lb_listener_rule|aws_lb_listener_certificate|aws_vpc_security_group_ingress_rule|aws_vpc_security_group_egress_rule'
allowed='aws_guardduty_malware_protection_plan'
# Autorisations par emplacement : "<type>@<fin du chemin du fichier>". Points de contact de
# l'ADR (règles et certificat sur l'écouteur partagé, règle 5432 sur le groupe de la base) et
# règles de NOTRE groupe de sécurité. Le contrôle du plan (check-plan-additions-only.sh) vérifie
# ensuite leurs adresses, leurs cibles et leurs attributs.
allowed_at=(
  "aws_lb_listener_rule@/modules/alb/main.tf"
  "aws_lb_listener_certificate@/modules/alb/main.tf"
  "aws_vpc_security_group_ingress_rule@/modules/shared_platform/main.tf"
  "aws_vpc_security_group_ingress_rule@/modules/ecs/main.tf"
  "aws_vpc_security_group_egress_rule@/modules/ecs/main.tf"
)

is_allowed_at() { # type fichier
  local entry
  for entry in "${allowed_at[@]+"${allowed_at[@]}"}"; do
    [ "${entry%%@*}" = "$1" ] && [[ "$2" == *"${entry#*@}" ]] && return 0
  done
  return 1
}

mapfile -t files < <(find "$root" -type f \( -name '*.tf' -o -name '*.tf.json' \) -not -path '*/.terraform/*' | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "::error::Aucun fichier .tf ni .tf.json sous $root."
  exit 1
fi

status=0

# 1. Types de ressources interdits (déclarations « resource "<type>" "<nom>" »).
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  type=$(sed -E 's/^[^"]*"([a-z0-9_]+)".*/\1/' <<< "${rest#*:}")
  if [[ "$type" =~ ^($allowed)$ ]]; then
    continue
  fi
  if [[ "$type" =~ ^($forbidden)$ ]]; then
    if is_allowed_at "$type" "$file"; then
      continue
    fi
    echo "::error file=$file,line=$line::Ressource $type interdite : elle agit sur tout le compte AWS partagé (CINAF, JobMinutes, Candidature Express)."
    status=1
  fi
done < <(grep -nHE '^[[:space:]]*resource[[:space:]]+"[a-z0-9_]+"' "${files[@]}" || true)

# 1 bis. Même contrôle dans les fichiers .tf.json : un type interdit utilisé comme clé JSON
# (« "resource": { "<type>": { ... } } »), quelle que soit la mise en forme.
mapfile -t json_files < <(printf '%s\n' "${files[@]}" | grep -E '\.tf\.json$' || true)
if [ "${#json_files[@]}" -gt 0 ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    type=$(sed -E 's/^[^"]*"([a-z0-9_]+)".*/\1/' <<< "${rest#*:}")
    if [[ "$type" =~ ^($allowed)$ ]] || is_allowed_at "$type" "$file"; then
      continue
    fi
    echo "::error file=$file,line=$line::Ressource $type interdite (.tf.json) : elle agit sur tout le compte AWS partagé (CINAF, JobMinutes, Candidature Express)."
    status=1
  done < <(grep -nHoE "\"($forbidden)\"[[:space:]]*:" "${json_files[@]}" || true)
fi

# 2. Sources de modules non locales (premier « source = » qui suit « module "<nom>" {»).
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  echo "::error file=${hit%%:*},line=$(cut -d: -f2 <<< "$hit")::Module non local ($(cut -d: -f3- <<< "$hit")) : contenu hors du contrôle des ressources interdites."
  status=1
done < <(awk '
  /^[[:space:]]*module[[:space:]]+"[^"]+"[[:space:]]*\{/ { want = 1; next }
  want && /^[[:space:]]*source[[:space:]]*=/ {
    src = $0; sub(/^[^"]*"/, "", src); sub(/".*$/, "", src)
    if (src !~ /^\.\.?\//) print FILENAME ":" FNR ":" src
    want = 0
  }
' "${files[@]}")

if [ "$status" -eq 0 ]; then
  echo "Aucune ressource à l'échelle du compte ni module non local dans ${#files[@]} fichiers Terraform ($root)."
fi
exit "$status"
