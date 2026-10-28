#!/usr/bin/env bash
# Tests of .github/scripts/register-task-revision.sh with a fake `aws` command (no AWS call):
# the revision must come from our registrar and belong to the expected Eventide family.
#   bash .github/scripts/tests/register-task-revision.test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../register-task-revision.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
SHA=0123456789abcdef0123456789abcdef01234567

mkdir -p "$work/bin"
# Fake AWS CLI: records its arguments, writes the Lambda response (last argument) per FAKE_MODE.
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
out="${*: -1}"
payload=""
prev=""
for a in "$@"; do [ "$prev" = "--payload" ] && payload="$a"; prev="$a"; done
key=$(jq -r .family <<< "$payload")
case "$FAKE_MODE" in
  ok) printf '{"taskDefinitionArn":"arn:aws:ecs:us-east-1:466494951409:task-definition/ev-prod-%s:12","family":"ev-prod-%s","revision":12}' "$key" "$key" > "$out"; echo None ;;
  foreign) printf '{"taskDefinitionArn":"arn:aws:ecs:us-east-1:466494951409:task-definition/cinaf-%s:3"}' "$key" > "$out"; echo None ;;
  refused) printf '{"errorMessage":"famille inconnue","errorType":"RegistrationRefused"}' > "$out"; echo Unhandled ;;
esac
FAKE
chmod +x "$work/bin/aws"

run() { # <mode> <args...> -> exit status, output in $out
  : > "$work/log" && : > "$work/env"
  out=$(env PATH="$work/bin:$PATH" FAKE_MODE="$1" FAKE_LOG="$work/log" GITHUB_ENV="$work/env" RUNNER_TEMP="$work" \
    TASK_REGISTRAR="${REGISTRAR:-ev-prod-task-registrar}" IMAGE_TAG="${TAG:-$SHA}" \
    API_FAMILY=ev-prod-api MIGRATE_FAMILY=ev-prod-migrate JOBS_FAMILY="${JOBS:-ev-prod-jobs}" \
    bash "$script" "${@:2}" 2>&1)
}
ok() { echo "OK   $1"; }
ko() { echo "ECHEC $1"; sed 's/^/      /' <<< "$out"; failures=$((failures + 1)); }

if run ok api API_TASKDEF migrate MIGRATE_TASKDEF &&
  grep -qx 'API_TASKDEF=arn:aws:ecs:us-east-1:466494951409:task-definition/ev-prod-api:12' "$work/env" &&
  grep -qx 'MIGRATE_TASKDEF=arn:aws:ecs:us-east-1:466494951409:task-definition/ev-prod-migrate:12' "$work/env" &&
  grep -q -- '--function-name ev-prod-task-registrar' "$work/log" &&
  grep -qF "{\"family\":\"api\",\"image_tag\":\"$SHA\"}" "$work/log" &&
  ! grep -qE 'describe-task-definition|register-task-definition' "$work/log"; then
  ok "révisions api et migrate par le registraire, sans lire ni écrire de définition de tâche"
else ko "révisions api et migrate"; fi

if ! run foreign jobs JOBS_TASKDEF && grep -q 'Révision inattendue' <<< "$out" && [ ! -s "$work/env" ]; then
  ok "révision d'une autre famille refusée"
else ko "révision d'une autre famille"; fi

if ! run refused api API_TASKDEF && grep -q 'Le registraire a refusé api : famille inconnue' <<< "$out" && [ ! -s "$work/env" ]; then
  ok "refus du registraire remonté"
else ko "refus du registraire"; fi

if ! REGISTRAR=cinaf-registrar run ok api API_TASKDEF && grep -q 'Registraire inattendu' <<< "$out" && [ ! -s "$work/log" ]; then
  ok "registraire hors d'Eventide refusé avant tout appel"
else ko "registraire hors d'Eventide"; fi

if ! TAG=latest run ok api API_TASKDEF && grep -q 'SHA de commit complet' <<< "$out" && [ ! -s "$work/log" ]; then
  ok "tag autre qu'un SHA refusé avant tout appel"
else ko "tag autre qu'un SHA"; fi

if ! JOBS=ce-prod-jobs run ok jobs JOBS_TASKDEF && grep -q "hors d'Eventide" <<< "$out" && [ ! -s "$work/log" ]; then
  ok "famille attendue hors d'Eventide refusée avant tout appel"
else ko "famille attendue hors d'Eventide"; fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) en échec."
  exit 1
fi
echo "Tous les tests de register-task-revision.sh sont verts."
