#!/usr/bin/env bash
# Tests of .github/scripts/check-plan-additions-only.sh on small JSON plans (tests/plans/,
# same shape as `terraform show -json tfplan`). No Terraform, no AWS.
#   bash .github/scripts/tests/check-plan-additions-only.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/../check-plan-additions-only.sh"
plans="$here/plans"
failures=0

# expect <exit code> <fixture> [--destroy] -- <substring>...
expect() {
  local code="$1" fixture="$2"
  shift 2
  local args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do args+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  local out status=0
  out=$(bash "$guard" "${args[@]+"${args[@]}"}" "$plans/$fixture" 2>&1) || status=$?
  if [ "$status" != "$code" ]; then
    echo "ECHEC $fixture ${args[*]-} : code $status au lieu de $code"
    sed 's/^/      /' <<< "$out"
    failures=$((failures + 1))
    return
  fi
  local needle
  for needle in "$@"; do
    if ! grep -qF -- "$needle" <<< "$out"; then
      echo "ECHEC $fixture ${args[*]-} : « $needle » absent"
      sed 's/^/      /' <<< "$out"
      failures=$((failures + 1))
      return
    fi
  done
  echo "OK   $fixture ${args[*]-} (code $code)"
}

expect 0 good-phase1.json -- \
  "module.prod.aws_vpc_security_group_ingress_rule.shared_postgres : create (tcp 5432 depuis notre groupe)" \
  "Ressources d'Eventide modifiées, remplacées, supprimées ou importées (à relire) :" "OK : aucune ressource"

# Phase 2 with the dashboard (30 October 2026): media family, task roles and their policies on
# our resources only, CORS and lifecycle of OUR content bucket: accepted, updates listed.
expect 0 good-phase2.json -- \
  "aws_lb_listener_rule.api : create (priorité 400 : api.eventide.app)" \
  "aws_lb_listener_rule.web[0] : create (priorité 401 : eventide.app, www.eventide.app)" \
  "aws_lb_listener_certificate.this : create" \
  "module.prod.module.ecs.aws_ecs_task_definition.api : delete,create" \
  "module.prod.aws_ssm_parameter.deploy_config : update" \
  "module.prod.module.task_registrar.aws_iam_role_policy.this : update" \
  "module.prod.module.content.aws_s3_bucket_lifecycle_configuration.this : update" \
  "Actions : 13 create, 1 delete,create, 1 no-op, 3 update"

# The same kinds of resources pointed at the other platforms.
expect 1 bad-media-iam.json -- \
  "ressource « arn:aws:s3:::cinaf-streaming-prod-media/* » qui n'est pas à Eventide (CinafMedia)" \
  "ressource « arn:aws:ecs:us-east-1:466494951409:task-definition/cinaf-streaming-api:* » qui n'est pas à Eventide (CinafTasks)" \
  "ressource « arn:aws:iam::466494951409:role/ce-prod-api-task » qui n'est pas à Eventide (CeRole)" \
  "secret:candidatureexpress/prod/* » qui n'est pas à Eventide (CeSecrets)" \
  "droit sur « * » (ReadEverything) : s3:GetObject, logs:FilterLogEvents" \
  "instruction Allow avec NotAction ou NotResource (AllButOurs) : interdite" \
  "droits IAM posés sur le rôle « cinaf-streaming-ecs-task » qui n'est pas à Eventide" \
  "politique « arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess » attachée" \
  "aws_iam_policy_attachment.s3 : type aws_iam_policy_attachment interdit" \
  "réglage S3 (aws_s3_bucket_cors_configuration) sur le bucket « cinaf-streaming-prod-media »" \
  "réglage S3 (aws_s3_bucket_lifecycle_configuration) sur le bucket « ce-prod-documents »" \
  "ÉCHEC : 11 violation(s)"

expect 1 bad-update-cinaf.json -- \
  "aws_security_group.cinaf_rds : ressource hors de la liste d'Eventide (aws_security_group, update)" \
  "shared_postgres : update sur un objet posé sur une ressource partagée" \
  "aws_vpc_security_group_egress_rule.extra : objet posé sur une ressource partagée hors des quatre points de contact" \
  "ÉCHEC : 3 violation(s)"

expect 1 bad-replace-listener.json -- \
  "module.prod.aws_lb_listener.https : type aws_lb_listener interdit" \
  "aws_lb_listener_rule.api : delete,create sur un objet posé sur une ressource partagée"

expect 1 bad-account-wide.json -- \
  "aws_guardduty_detector.this : type aws_guardduty_detector interdit" \
  "aws_ecs_account_setting_default.insights : type aws_ecs_account_setting_default interdit" \
  "aws_service_discovery_private_dns_namespace.internal : type aws_service_discovery_private_dns_namespace interdit" \
  "aws_vpc_endpoint.s3 : type aws_vpc_endpoint interdit" \
  "ÉCHEC : 4 violation(s)"

expect 1 bad-listener-rule.json -- \
  "priorité 300 hors des plages d'Eventide" \
  "conditions autres que host_header interdites : path_pattern" \
  "nom d'hôte « api.candidatureexpress.com » hors de notre domaine" \
  "nom d'hôte « *.eventide.app »" \
  "nom d'hôte « noteventide.app »" \
  "action d'écoute autre que forward : redirect" \
  "aws_lb_listener_rule.extra : objet posé sur une ressource partagée hors des quatre points de contact"

expect 1 bad-postgres-rule.json -- \
  "tcp 5432 seulement (lu : tcp 0-65535)" \
  "avec un bloc CIDR ou une liste de préfixes : interdit" \
  "sans groupe source" \
  "module.preprod[0].aws_vpc_security_group_ingress_rule.shared_postgres : import d'un objet posé sur une ressource partagée"

expect 1 bad-names-tags.json -- \
  "étiquette Project = cinaf (attendu : eventide)" \
  "nom « cinaf-backups » sans préfixe d'Eventide (bucket)" \
  "filtre de métrique sur un groupe de journaux qui n'est pas à Eventide : /ecs/cinaf-streaming-prod/api" \
  "action d'alarme autre qu'une publication SNS : arn:aws:automate:us-east-1:ec2:stop" \
  "nom « ce-prod-api » sans préfixe d'Eventide (family)"

# A destroy plan removes our contact points: refused as an apply plan, accepted with --destroy.
expect 1 destroy.json -- "shared_postgres : delete sur un objet posé sur une ressource partagée"
expect 0 destroy.json --destroy -- \
  "shared_postgres : delete (retrait de notre ajout)" "aws_lb_listener_rule.api : delete (retrait de notre ajout)" "OK (destruction)"

expect 2 not-a-plan.json -- "n'est pas la sortie de « terraform show -json <plan> »"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) en échec."
  exit 1
fi
echo "Tous les tests du contrôle de plan sont verts."
