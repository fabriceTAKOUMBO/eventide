# Tâche <env>-db-backup, conteneur « upload » (AWS CLI) : envoie la sauvegarde dans le bucket
# S3 (chiffrement SSE-KMS par défaut du bucket, versionné, expiration à 35 jours).
# Aucun en-tête de chiffrement n'est envoyé (ni --sse, ni --sse-kms-key-id) : la politique du
# bucket les refuse s'ils désignent une autre clé que la nôtre, et le chiffrement par défaut du
# bucket applique notre clé KMS (y compris pour un envoi en plusieurs parties).
# L'événement db_backup_uploaded alimente l'alarme « aucune sauvegarde depuis 24 h ».
set -eu
# shellcheck disable=SC2034 # lu par fail() (lib.sh, concaténé devant ce script)
FAIL_EVENT=db_backup_failed

require_vars BACKUP_BUCKET BACKUP_PREFIX
require_identifiers EV_DB_NAME
require_marker dump.ok "pg_dump en echec (voir le flux dump)"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
key="$BACKUP_PREFIX/$(date -u +%Y/%m/%d)/$EV_DB_NAME-$stamp.pgc"
aws s3 cp "$WORK_DIR/dump.pgc" "s3://$BACKUP_BUCKET/$key" --only-show-errors --no-progress ||
  fail "envoi S3"
bytes=$(wc -c < "$WORK_DIR/dump.pgc")
printf '{"event":"db_backup_uploaded","bucket":"%s","key":"%s","bytes":%s}\n' "$BACKUP_BUCKET" "$key" "$bytes"
# Le fichier a été écrit par le conteneur « dump » (autre utilisateur) : son effacement peut
# être refusé. Sans conséquence : le volume éphémère (chiffré) disparaît avec la tâche.
rm -f "$WORK_DIR/dump.pgc" 2>/dev/null || true
