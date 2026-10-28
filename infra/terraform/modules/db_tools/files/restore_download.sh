# Tâche <env>-db-restore-test, conteneur « download » (AWS CLI) : récupère la sauvegarde à
# tester (BACKUP_KEY, ou la plus récente du préfixe) dans le volume de travail.
set -eu
# shellcheck disable=SC2034 # lu par fail() (lib.sh, concaténé devant ce script)
FAIL_EVENT=db_restore_test_failed

require_vars BACKUP_BUCKET BACKUP_PREFIX
require_marker init.ok "volume de travail non prepare"

key="${BACKUP_KEY:-}"
if [ -z "$key" ]; then
  key=$(aws s3api list-objects-v2 --bucket "$BACKUP_BUCKET" --prefix "$BACKUP_PREFIX/" \
    --query 'sort_by(Contents, &LastModified)[-1].Key' --output text) || fail "liste S3"
fi
case "$key" in
  "" | None) fail "aucune sauvegarde dans s3://$BACKUP_BUCKET/$BACKUP_PREFIX/" ;;
esac
aws s3 cp "s3://$BACKUP_BUCKET/$key" "$WORK_DIR/dump.pgc" --only-show-errors --no-progress ||
  fail "telechargement S3"
printf '%s' "$key" > "$WORK_DIR/key.txt"
touch "$WORK_DIR/download.ok"
printf '{"event":"db_restore_download_done","key":"%s","bytes":%s}\n' "$key" "$(wc -c < "$WORK_DIR/dump.pgc")"
