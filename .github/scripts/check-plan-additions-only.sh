#!/usr/bin/env bash
# Plan guard of Eventide in the SHARED AWS account (466494951409, us-east-1: CINAF, JobMinutes,
# Candidature Express). Reads the JSON of a saved plan and FAILS unless the plan leaves every
# resource of the other platforms untouched (AGENTS.md, « RÈGLE ABSOLUE », rules 1, 2, 3, 4, 6;
# docs/infra/hebergement-mutualise.md). Mandatory before EVERY apply (runbook), in addition to
# the product owner's review; it never replaces that review.
#
#   terraform plan -out=tfplan
#   terraform show -json tfplan > tfplan.json
#   bash .github/scripts/check-plan-additions-only.sh tfplan.json            # apply plans
#   bash .github/scripts/check-plan-additions-only.sh --destroy tfplan.json  # terraform plan -destroy
#
# Each resource change of the plan is put in one class:
#   - data source            : read only, always accepted;
#   - forbidden type         : a resource type of the shared infrastructure (ALB, listener, RDS,
#                              VPC, subnets, NAT, routes, legacy SG rules, VPC endpoints, WAF
#                              associations, private DNS…) or an account/region-wide setting:
#                              refused whatever the action (even no-op: our state must never
#                              manage one);
#   - contact point          : an object placed ON a shared resource. Only the four kinds of the
#                              ADR, at their exact addresses: our listener rules (priorities
#                              400-409 / 420-429, host_header only, host names inside our domain,
#                              no wildcard, forward only), our listener certificate, the
#                              standalone 5432 ingress rule on the database security group
#                              (source = our group, never a CIDR). Only create or no-op (delete
#                              too with --destroy); never update, replace, forget or import;
#   - Eventide resource      : address in the Eventide allowlist (module.prod, module.preprod,
#                              root guardrails, bootstrap state). Any action is accepted, but
#                              every update, replace, delete, forget or import is LISTED for
#                              the review. Creates are checked: tag Project = eventide, names
#                              with our prefixes (ev-, eventide, /ecs/ev-, /eventide/…), metric
#                              filters on our log groups only, alarm actions = SNS only;
#   - anything else          : refused (not in the allowlist).
# A security group rule whose security group is a SHARED one (read from the data sources of the
# plan) is a contact point whatever its address.
#
# Exit codes: 0 = OK, 1 = at least one violation, 2 = usage error or unreadable plan.
# Requires bash and jq (same tools as the runbook). Tested by
# .github/scripts/tests/check-plan-additions-only.test.sh (fixtures in tests/plans/).
set -euo pipefail

mode=apply
plan=""
for arg in "$@"; do
  case "$arg" in
    --destroy) mode=destroy ;;
    -h | --help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    -*)
      echo "Option inconnue : $arg" >&2
      exit 2
      ;;
    *)
      [ -z "$plan" ] || { echo "Un seul fichier de plan." >&2; exit 2; }
      plan="$arg"
      ;;
  esac
done
if [ -z "$plan" ]; then
  echo "Usage : check-plan-additions-only.sh [--destroy] <plan.json>   (terraform show -json tfplan > plan.json)" >&2
  exit 2
fi
if [ ! -r "$plan" ]; then
  echo "Plan illisible : $plan" >&2
  exit 2
fi
command -v jq > /dev/null || { echo "jq est requis." >&2; exit 2; }
if ! jq -e 'type == "object" and has("format_version") and ((.resource_changes // []) | type == "array")' "$plan" > /dev/null 2>&1; then
  echo "Ce fichier n'est pas la sortie de « terraform show -json <plan> » : $plan" >&2
  exit 2
fi

# shellcheck disable=SC2016 # jq program, not shell expansions
program='
def env_re: "module\\.(prod|preprod\\[0\\])";

# Eventide-owned addresses (envs/shared-prod and bootstrap stacks).
def owned_re:
  "^(module\\.(prod|preprod(\\[0\\])?)\\.|terraform_data\\.|aws_budgets_budget\\.monthly(\\[0\\])?$|"
  + "aws_ce_anomaly_monitor\\.project(\\[0\\])?$|aws_ce_anomaly_subscription\\.project(\\[0\\])?$|"
  + "aws_kms_key\\.state$|aws_kms_alias\\.state$|aws_s3_bucket(_[a-z_]+)?\\.state$)";

# The only objects allowed ON a shared resource (ADR § 5), by exact address.
def contact_kind:
  if test("^" + env_re + "\\.module\\.alb\\[0\\]\\.aws_lb_listener_rule\\.(api|web\\[0\\])$") then "listener_rule"
  elif test("^" + env_re + "\\.module\\.alb\\[0\\]\\.aws_lb_listener_certificate\\.this$") then "listener_certificate"
  elif test("^" + env_re + "\\.aws_vpc_security_group_ingress_rule\\.shared_postgres$") then "postgres_ingress"
  else null end;

# Types that would manage a resource of CINAF, JobMinutes or Candidature Express, or act on the
# whole account or region. Keep in line with .github/scripts/check-shared-account-resources.sh.
def forbidden_re:
  "^(aws_lb|aws_alb|aws_elb|aws_lb_listener|aws_alb_listener|aws_alb_listener_rule|aws_alb_listener_certificate"
  + "|aws_lb_target_group_attachment|aws_alb_target_group_attachment|aws_lb_cookie_stickiness_policy|aws_lb_ssl_negotiation_policy"
  + "|aws_wafv2_web_acl_association|aws_waf_[a-z0-9_]+|aws_wafregional_[a-z0-9_]+|aws_shield_[a-z0-9_]+"
  + "|aws_db_[a-z0-9_]+|aws_rds_[a-z0-9_]+"
  + "|aws_vpc|aws_subnet|aws_nat_gateway|aws_internet_gateway|aws_egress_only_internet_gateway|aws_eip_association"
  + "|aws_route|aws_route_table|aws_route_table_association|aws_main_route_table_association"
  + "|aws_network_acl|aws_network_acl_rule|aws_network_acl_association|aws_security_group_rule"
  + "|aws_vpc_endpoint|aws_vpc_endpoint_[a-z0-9_]+|aws_vpc_ipv4_cidr_block_association|aws_vpc_ipv6_cidr_block_association"
  + "|aws_vpc_dhcp_options|aws_vpc_dhcp_options_association|aws_flow_log|aws_ec2_traffic_mirror_[a-z0-9_]+|aws_ec2_tag"
  + "|aws_route53_zone|aws_route53_zone_association|aws_route53_vpc_association_authorization|aws_route53_resolver_[a-z0-9_]+"
  + "|aws_service_discovery_private_dns_namespace|aws_iam_openid_connect_provider|aws_iam_saml_provider"
  + "|aws_cloudwatch_log_subscription_filter|aws_cloudwatch_log_resource_policy|aws_cloudwatch_log_account_policy"
  + "|aws_cloudwatch_event_bus_policy|aws_cloudwatch_event_permission|aws_cloudwatch_event_archive|aws_cloudtrail"
  + "|aws_default_[a-z0-9_]+|aws_guardduty_[a-z0-9_]+|aws_securityhub_[a-z0-9_]+|aws_config_[a-z0-9_]+"
  + "|aws_s3_account_public_access_block|aws_s3control_[a-z0-9_]+|aws_iam_account_password_policy|aws_iam_account_alias"
  + "|aws_iam_service_linked_role|aws_iam_security_token_service_preferences|aws_organizations_[a-z0-9_]+"
  + "|aws_account_[a-z0-9_]+|aws_ram_sharing_with_organization|aws_ebs_encryption_by_default|aws_ebs_default_kms_key"
  + "|aws_ebs_snapshot_block_public_access|aws_ec2_image_block_public_access|aws_ec2_serial_console_access"
  + "|aws_ec2_instance_metadata_defaults|aws_vpc_block_public_access_[a-z0-9_]+|aws_ecs_account_setting_default"
  + "|aws_ecr_account_setting|aws_ecr_registry_[a-z0-9_]+|aws_ecr_replication_configuration|aws_ecr_pull_through_cache_rule"
  + "|aws_api_gateway_account|aws_xray_encryption_config|aws_macie2_[a-z0-9_]+|aws_inspector2_[a-z0-9_]+"
  + "|aws_detective_[a-z0-9_]+|aws_securitylake_[a-z0-9_]+|aws_fms_[a-z0-9_]+|aws_sesv2_account_[a-z0-9_]+"
  + "|aws_ses_active_receipt_rule_set|aws_sns_sms_preferences|aws_ssm_service_setting|aws_ssm_default_patch_baseline"
  + "|aws_ce_cost_allocation_tag|aws_resourceexplorer2_index|aws_backup_global_settings|aws_backup_region_settings"
  + "|aws_accessanalyzer_analyzer|aws_auditmanager_account_registration|aws_emr_block_public_access_configuration"
  + "|aws_glue_data_catalog_encryption_settings|aws_glue_resource_policy|aws_lakeformation_data_lake_settings"
  + "|aws_lambda_layer_version_permission)$";

def name_attrs: {
  aws_iam_role: "name", aws_ecs_cluster: "name", aws_lb_target_group: "name", aws_security_group: "name",
  aws_sns_topic: "name", aws_cloudwatch_event_rule: "name", aws_scheduler_schedule_group: "name",
  aws_scheduler_schedule: "name", aws_cloudfront_public_key: "name", aws_cloudfront_key_group: "name",
  aws_cloudfront_cache_policy: "name", aws_cloudfront_origin_access_control: "name",
  aws_ecr_repository: "name", aws_lambda_function: "function_name", aws_kms_alias: "name",
  aws_secretsmanager_secret: "name", aws_ssm_parameter: "name", aws_cloudwatch_log_group: "name",
  aws_cloudwatch_metric_alarm: "alarm_name", aws_cloudwatch_log_metric_filter: "name",
  aws_ecs_task_definition: "family", aws_s3_bucket: "bucket", aws_budgets_budget: "name",
  aws_ce_anomaly_monitor: "name", aws_ce_anomaly_subscription: "name",
  aws_appautoscaling_policy: "name", aws_appautoscaling_scheduled_action: "name"
};
def own_name_re: "^(ev-|eventide|alias/ev-|alias/eventide|/ecs/ev-|/aws/lambda/ev-|/eventide/)";

def err($a; $msg): {level: "ERROR", address: $a, msg: $msg};
def review($a; $msg): {level: "REVIEW", address: $a, msg: $msg};
def contact($a; $msg): {level: "CONTACT", address: $a, msg: $msg};

# Security groups of the shared infrastructure, read by the data sources of the plan.
([.. | objects | select(.mode? == "data" and (.type? | type) == "string" and (.values? | type) == "object")
  | if .type == "aws_security_group" then .values.id
    elif .type == "aws_lb" then (.values.security_groups // [])[]
    elif .type == "aws_db_instance" then (.values.vpc_security_groups // [])[]
    else empty end
  | strings]
  # The database security group is also a root variable of envs/shared-prod.
  + [.variables.rds_security_group_id.value // empty | strings] | unique) as $shared_sgs
| ((.variables.domain_name.value // "") | ascii_downcase) as $domain
| [ .resource_changes // [] | .[]
    | . as $rc
    | $rc.address as $a
    | ($rc.change.actions // []) as $acts
    | ($acts | join(",")) as $label
    | (($acts == ["no-op"]) or ($acts == ["read"])) as $is_noop
    | ($acts == ["create"]) as $is_create
    | ($acts == ["delete"]) as $is_delete
    | ($rc.change.after // {}) as $after
    | ($rc.change.before // {}) as $before
    | ($rc.change.after_unknown // {}) as $unknown
    | ($rc.address | contact_kind) as $kind
    | (($rc.type | test("^aws_vpc_security_group_(ingress|egress)_rule$"))
        and ((($after.security_group_id // "") as $s | $shared_sgs | index($s))
          or (($before.security_group_id // "") as $s | $shared_sgs | index($s)))) as $on_shared_sg
    | if $rc.mode == "data" then empty

      elif ($rc.type | test(forbidden_re)) then
        err($a; "type \($rc.type) interdit : ressource partagée de CINAF, JobMinutes ou Candidature Express, ou réglage de tout le compte (\($label))")

      elif ($kind != null) or ($rc.type | test("^aws_(lb|alb)_listener_(rule|certificate)$")) or $on_shared_sg then
        if $kind == null then
          err($a; "objet posé sur une ressource partagée hors des quatre points de contact de l'\''ADR (\($rc.type), \($label))")
        elif ($kind == "postgres_ingress") and ($rc.type != "aws_vpc_security_group_ingress_rule") then
          err($a; "point de contact de type inattendu : \($rc.type)")
        elif $rc.change.importing != null then
          err($a; "import d'\''un objet posé sur une ressource partagée : interdit (règle 1)")
        elif $is_noop then empty
        elif $is_delete and $mode == "destroy" then contact($a; "delete (retrait de notre ajout)")
        elif $is_create then
          ( if $kind == "listener_rule" then
              ($after.priority) as $p
              | ([$after.condition[]? ]) as $conds
              | ([$conds[] | (.host_header // [])[] | (.values // [])[] ]) as $hosts
              | ( if ($p | type) != "number" or (($p < 400 or $p > 409) and ($p < 420 or $p > 429))
                  then err($a; "priorité \($p) hors des plages d'\''Eventide (400-409, 420-429)") else empty end ),
                ( if ($conds | length) == 0 or any($conds[]; ((.host_header // []) | length) == 0)
                  then err($a; "règle d'\''écouteur sans condition host_header sur chaque condition") else empty end ),
                ( [$conds[] | to_entries[] | select(.key != "host_header" and ((.value // []) | length) > 0) | .key] | unique
                  | if length > 0 then err($a; "conditions autres que host_header interdites : \(join(", "))") else empty end ),
                ( if $domain == "" then err($a; "règle d'\''écouteur sans domain_name dans le plan") else empty end ),
                ( $hosts[] | ascii_downcase | select(test("[*?]") or ($domain == "") or (. != $domain and (endswith("." + $domain) | not)))
                  | err($a; "nom d'\''hôte « \(.) » hors de notre domaine « \($domain) » ou avec joker") ),
                ( [$after.action[]? | .type] | map(select(. != "forward")) | unique
                  | if length > 0 then err($a; "action d'\''écoute autre que forward : \(join(", "))") else empty end ),
                contact($a; "create (priorité \($p) : \($hosts | join(", ")))")
            elif $kind == "postgres_ingress" then
              ( if $after.ip_protocol != "tcp" or $after.from_port != 5432 or $after.to_port != 5432
                then err($a; "règle d'\''entrée sur le groupe de la base : tcp 5432 seulement (lu : \($after.ip_protocol) \($after.from_port)-\($after.to_port))") else empty end ),
              ( if ($after.cidr_ipv4 != null) or ($after.cidr_ipv6 != null) or ($after.prefix_list_id != null)
                then err($a; "règle d'\''entrée sur le groupe de la base avec un bloc CIDR ou une liste de préfixes : interdit") else empty end ),
              ( if ($after.referenced_security_group_id == null) and (($unknown.referenced_security_group_id // false) != true)
                then err($a; "règle d'\''entrée sur le groupe de la base sans groupe source") else empty end ),
              ( ($after.referenced_security_group_id // "") as $src
                | if ($src != "") and ($shared_sgs | index($src)) then err($a; "source de la règle 5432 : un groupe partagé (\($src)), pas le nôtre") else empty end ),
              ( if ($shared_sgs | length) > 0 and ((($after.security_group_id // "") as $s | $shared_sgs | index($s)) | not)
                  and (($unknown.security_group_id // false) != true)
                then err($a; "règle 5432 posée ailleurs que sur le groupe de la base partagée (\($after.security_group_id))") else empty end ),
              contact($a; "create (tcp 5432 depuis notre groupe)")
            else
              contact($a; "create")
            end )
        else
          err($a; "\($label) sur un objet posé sur une ressource partagée : seulement create ou no-op (delete avec --destroy)")
        end

      elif ($rc.address | test(owned_re)) then
        ( if $rc.change.importing != null then review($a; "import (\($rc.change.importing.id // "?"))") else empty end ),
        ( if $is_noop or $is_create then empty
          elif $is_delete and $mode == "destroy" then empty
          else review($a; $label) end ),
        ( if $is_create then
            ( if ($after | has("tags_all")) and ($after.tags_all | type) == "object" and ($after.tags_all.Project != "eventide")
              then err($a; "étiquette Project = \($after.tags_all.Project // "absente") (attendu : eventide)") else empty end ),
            ( (name_attrs | .[$rc.type]) as $attr
              | if $attr == null then empty
                else ($after[$attr] // null) as $n
                | if ($n | type) == "string" and ($n | test(own_name_re) | not)
                  then err($a; "nom « \($n) » sans préfixe d'\''Eventide (\($attr))") else empty end
                end ),
            ( if $rc.type == "aws_cloudwatch_log_metric_filter" and (($after.log_group_name // "") | type) == "string"
                and ($after.log_group_name != null) and (($after.log_group_name | test("^(/ecs/ev-|/aws/lambda/ev-)")) | not)
              then err($a; "filtre de métrique sur un groupe de journaux qui n'\''est pas à Eventide : \($after.log_group_name)") else empty end ),
            ( if $rc.type == "aws_cloudwatch_metric_alarm" then
                [($after.alarm_actions // [])[], ($after.ok_actions // [])[], ($after.insufficient_data_actions // [])[]]
                | map(select(type == "string" and (startswith("arn:aws:sns:") | not)))
                | if length > 0 then err($a; "action d'\''alarme autre qu'\''une publication SNS : \(join(", "))") else empty end
              else empty end )
          else empty end )

      else
        err($a; "ressource hors de la liste d'\''Eventide (\($rc.type), \($label)) : rien d'\''autre que nos ressources ne doit figurer dans le plan")
      end
  ] as $findings
| {
    findings: $findings,
    counts: ([.resource_changes // [] | .[] | select(.mode != "data") | .change.actions | join(",")] | group_by(.) | map({key: .[0], value: length}) | from_entries),
    shared_sgs: $shared_sgs,
    domain: $domain
  }
'

result=$(jq --arg mode "$mode" "$program" "$plan")

echo "Plan : $plan (mode $mode)"
echo "Actions : $(jq -r '.counts | to_entries | map("\(.value) \(.key)") | join(", ") | if . == "" then "aucune" else . end' <<< "$result")"
echo "Groupes de sécurité partagés lus dans le plan : $(jq -r '.shared_sgs | if length == 0 then "aucun" else join(", ") end' <<< "$result")"
if [ "$(jq '.shared_sgs | length' <<< "$result")" = "0" ] && [ "$(jq '[.resource_changes // [] | .[] | select(.type | test("security_group"))] | length' "$plan")" != "0" ]; then
  echo "AVERTISSEMENT : aucun groupe de sécurité partagé lu dans le plan : les règles de groupe ne sont contrôlées que par leur adresse."
fi

contacts=$(jq -r '.findings[] | select(.level == "CONTACT") | "  \(.address) : \(.msg)"' <<< "$result")
echo "Ajouts sur des ressources de CINAF (points de contact de l'ADR) :"
echo "${contacts:-  aucun}"

reviews=$(jq -r '.findings[] | select(.level == "REVIEW") | "  \(.address) : \(.msg)"' <<< "$result")
echo "Ressources d'Eventide modifiées, remplacées, supprimées ou importées (à relire) :"
echo "${reviews:-  aucune}"

errors=$(jq -r '.findings[] | select(.level == "ERROR") | "  \(.address) : \(.msg)"' <<< "$result")
if [ -n "$errors" ]; then
  echo "VIOLATIONS de la règle absolue (CINAF, JobMinutes, Candidature Express intouchées) :"
  echo "$errors"
  echo "ÉCHEC : $(grep -c . <<< "$errors") violation(s). Ne pas appliquer ce plan ; signaler."
  exit 1
fi
if [ "$mode" = "destroy" ]; then
  echo "OK (destruction) : seules des ressources d'Eventide et nos ajouts sur les ressources de CINAF sont retirés ; aucune ressource d'une autre plateforme n'est touchée. La relecture du plan par le product owner reste obligatoire."
else
  echo "OK : aucune ressource d'une autre plateforme n'est modifiée, remplacée, supprimée ni importée ; seuls nos ajouts permis. La relecture du plan par le product owner reste obligatoire."
fi
