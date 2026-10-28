# Tâche <env>-db-backup, conteneur « dump » (client PostgreSQL 16) : pg_dump de la base
# applicative au format personnalisé (compressé), connecté avec le rôle en lecture seule.
# Le conteneur « upload » envoie ensuite le fichier dans le bucket S3 des sauvegardes.
set -eu
# shellcheck disable=SC2034 # lu par fail() (lib.sh, concaténé devant ce script)
FAIL_EVENT=db_backup_failed

require_vars PGHOST PGPORT PGUSER PGPASSWORD
require_identifiers PGDATABASE
require_marker init.ok "volume de travail non prepare"
setup_tls

start=$(date -u +%s)
# Compteurs de limites de débit : structure sauvegardée, contenu éphémère exclu (2 jours).
pg_dump --format=custom --compress=6 --no-password --lock-wait-timeout=60s \
  --exclude-table-data=core_ratecounter \
  --file="$WORK_DIR/dump.pgc" || fail "pg_dump"
# Contrôle de lecture de l'archive (table des matières complète).
pg_restore --list "$WORK_DIR/dump.pgc" > "$WORK_DIR/dump.toc" || fail "archive illisible"
objects=$(grep -vc '^;' "$WORK_DIR/dump.toc" || true)
bytes=$(wc -c < "$WORK_DIR/dump.pgc")
end=$(date -u +%s)
touch "$WORK_DIR/dump.ok"
printf '{"event":"db_dump_done","database":"%s","objects":%s,"bytes":%s,"seconds":%s}\n' \
  "$PGDATABASE" "$objects" "$bytes" "$((end - start))"
