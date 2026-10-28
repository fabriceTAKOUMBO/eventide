#!/usr/bin/env bash
# Registers new revisions of OUR ECS task definition families through OUR task registrar (Lambda
# ev-<env>-task-registrar, infra/terraform/modules/task_registrar), used by the Deploy workflow.
#
# Shared AWS account (CINAF, JobMinutes, Candidature Express): the deploy role never reads nor
# writes a task definition itself (no ecs:DescribeTaskDefinition, no ecs:RegisterTaskDefinition).
# It only invokes the registrar with a family KEY of Eventide (api, migrate, jobs) and the
# commit SHA; the registrar builds the revision from Terraform's template and refuses anything
# else. This script checks that the revision returned belongs to the expected family.
#
# Usage: register-task-revision.sh <key> <ENV_VAR> [<key> <ENV_VAR> ...]
#   e.g. register-task-revision.sh api API_TASKDEF migrate MIGRATE_TASKDEF
# Environment: TASK_REGISTRAR (function name), IMAGE_TAG (40 hex characters), <KEY>_FAMILY
# (expected family, e.g. API_FAMILY=ev-prod-api), GITHUB_ENV (file receiving ENV_VAR=<arn>),
# RUNNER_TEMP (work directory).
set -euo pipefail

: "${TASK_REGISTRAR:?TASK_REGISTRAR absent (configuration SSM du déploiement)}"
: "${IMAGE_TAG:?IMAGE_TAG absent}"
: "${GITHUB_ENV:?GITHUB_ENV absent}"
work="${RUNNER_TEMP:-$(mktemp -d)}"

if [ "$#" -eq 0 ] || [ $(($# % 2)) -ne 0 ]; then
  echo "::error::Usage : register-task-revision.sh <clé> <VARIABLE> [<clé> <VARIABLE> ...]"
  exit 2
fi
if ! [[ "$TASK_REGISTRAR" =~ ^ev-[a-z0-9]+-task-registrar$ ]]; then
  echo "::error::Registraire inattendu : $TASK_REGISTRAR (attendu : ev-<env>-task-registrar)."
  exit 1
fi
if ! [[ "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::IMAGE_TAG doit être un SHA de commit complet."
  exit 1
fi

while [ "$#" -gt 0 ]; do
  key="$1" var="$2"
  shift 2
  if ! [[ "$key" =~ ^[a-z0-9]+$ ]] || ! [[ "$var" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "::error::Arguments invalides : $key $var"
    exit 2
  fi
  family_var="$(tr '[:lower:]' '[:upper:]' <<< "$key")_FAMILY"
  expected="${!family_var:-}"
  if ! [[ "$expected" =~ ^ev-[a-z0-9]+-$key$ ]]; then
    echo "::error::Famille attendue pour $key absente ou hors d'Eventide ($family_var=$expected)."
    exit 1
  fi

  out="$work/register-$key.json"
  payload=$(jq -nc --arg f "$key" --arg t "$IMAGE_TAG" '{family: $f, image_tag: $t}')
  function_error=$(aws lambda invoke --function-name "$TASK_REGISTRAR" \
    --cli-binary-format raw-in-base64-out --payload "$payload" \
    --query FunctionError --output text "$out")
  if [ -n "$function_error" ] && [ "$function_error" != "None" ]; then
    echo "::error::Le registraire a refusé $key : $(jq -r '.errorMessage // tostring' "$out" 2>/dev/null || cat "$out")"
    exit 1
  fi

  arn=$(jq -r '.taskDefinitionArn // empty' "$out")
  if ! [[ "$arn" =~ ^arn:aws:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/${expected}:[0-9]+$ ]]; then
    echo "::error::Révision inattendue pour $key : '$arn' (famille attendue : $expected)."
    exit 1
  fi
  echo "$var=$arn" >> "$GITHUB_ENV"
  echo "$expected -> $arn"
done
