#!/usr/bin/env bash
# Tests of .github/scripts/check-shared-account-resources.sh (static guard of the Terraform code)
# on small throwaway configurations. No Terraform, no AWS.
#   bash .github/scripts/tests/check-shared-account-resources.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/../check-shared-account-resources.sh"
repo="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

case_dir() { # <name> <relative file> <content>
  mkdir -p "$work/$1/$(dirname "$2")"
  printf '%s\n' "$3" > "$work/$1/$2"
}
expect() { # <code> <name> <substring>
  local out status=0
  out=$(bash "$guard" "$work/$2" 2>&1) || status=$?
  if [ "$status" = "$1" ] && grep -qF -- "$3" <<< "$out"; then
    echo "OK   $2"
  else
    echo "ECHEC $2 (code $status, attendu $1, « $3 »)"
    sed 's/^/      /' <<< "$out"
    failures=$((failures + 1))
  fi
}

case_dir contact-points-in-place modules/alb/main.tf 'resource "aws_lb_listener_rule" "api" {}
resource "aws_lb_listener_certificate" "this" {}'
case_dir contact-points-in-place modules/shared_platform/main.tf 'resource "aws_vpc_security_group_ingress_rule" "shared_postgres" {}'
expect 0 contact-points-in-place "Aucune ressource"

case_dir listener-rule-elsewhere modules/observability/main.tf 'resource "aws_lb_listener_rule" "debug" {}'
expect 1 listener-rule-elsewhere "Ressource aws_lb_listener_rule interdite"

case_dir sg-rule-elsewhere modules/db_tools/main.tf 'resource "aws_vpc_security_group_egress_rule" "x" {}'
expect 1 sg-rule-elsewhere "Ressource aws_vpc_security_group_egress_rule interdite"

case_dir shared-vpc-endpoint main.tf 'resource "aws_vpc_endpoint" "s3" {}'
expect 1 shared-vpc-endpoint "Ressource aws_vpc_endpoint interdite"

case_dir private-dns main.tf '  resource "aws_service_discovery_private_dns_namespace" "internal" {}'
expect 1 private-dns "Ressource aws_service_discovery_private_dns_namespace interdite"

case_dir shared-listener main.tf 'resource "aws_lb_listener" "https" {}'
expect 1 shared-listener "Ressource aws_lb_listener interdite"

case_dir account-setting main.tf 'resource "aws_ecr_account_setting" "x" {}'
expect 1 account-setting "Ressource aws_ecr_account_setting interdite"

case_dir json-form main.tf.json '{"resource": {"aws_db_parameter_group": {"x": {}}}}'
expect 1 json-form "Ressource aws_db_parameter_group interdite (.tf.json)"

# Exclusive attachment of a policy across the whole account (would detach it elsewhere).
case_dir exclusive-policy-attachment modules/ecs/main.tf 'resource "aws_iam_policy_attachment" "s3" {}'
expect 1 exclusive-policy-attachment "Ressource aws_iam_policy_attachment interdite"

# Our dashboard resources (CORS on our bucket, task roles, inline policies) are allowed.
case_dir dashboard-resources modules/content_cdn/main.tf 'resource "aws_s3_bucket_cors_configuration" "this" {}
resource "aws_iam_role_policy" "task" {}
resource "aws_iam_role" "task" {}'
expect 0 dashboard-resources "Aucune ressource"

expect_repo() {
  local out status=0
  out=$(bash "$guard" "$repo/infra/terraform" 2>&1) || status=$?
  if [ "$status" = 0 ]; then echo "OK   infra/terraform du dépôt"; else echo "ECHEC infra/terraform du dépôt"; echo "$out"; failures=$((failures + 1)); fi
}
expect_repo

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) en échec."
  exit 1
fi
echo "Tous les tests du contrôle statique sont verts."
