# Tâche <env>-db-restore-test, conteneur « restore » (client PostgreSQL 16) : restaure la
# sauvegarde dans la base temporaire <restore_db> (même instance, propriétaire <migrator>),
# compare tables et lignes avec la base source, puis vide la copie (KEEP_RESTORED=true pour
# la garder le temps d'un contrôle manuel ; relancer alors la tâche pour la vider).
# Code de sortie 0 seulement si la restauration réussit et que les tables sont les mêmes.
#
# Incident uniquement (docs/runbooks/premier-deploiement.md § 12) : avec les surcharges
# EV_RESTORE_DB_NAME = base applicative, KEEP_RESTORED=true et RESTORE_WITH_PRIVILEGES=true,
# la même tâche remplace le contenu de la base applicative par la sauvegarde, droits et
# privilèges par défaut compris (services arrêtés au préalable).
set -eu
# shellcheck disable=SC2034 # lu par fail() (lib.sh, concaténé devant ce script)
FAIL_EVENT=db_restore_test_failed

require_vars PGHOST PGPORT MIGRATOR_DB_PASSWORD EV_SQL_COUNT
require_identifiers EV_DB_NAME EV_RESTORE_DB_NAME EV_MIGRATOR_ROLE
require_own_databases EV_DB_NAME EV_RESTORE_DB_NAME
require_own_roles EV_MIGRATOR_ROLE
# Target: the restore-test database, or the application database itself (incident procedure).
case "$EV_RESTORE_DB_NAME" in
  "$EV_DB_NAME" | "${EV_DB_NAME}"_*) ;;
  *) fail "base de restauration $EV_RESTORE_DB_NAME sans rapport avec $EV_DB_NAME" ;;
esac
require_marker download.ok "telechargement en echec (voir le flux download)"
setup_tls

PGUSER="$EV_MIGRATOR_ROLE"
PGPASSWORD="$MIGRATOR_DB_PASSWORD"
export PGUSER PGPASSWORD
key=$(cat "$WORK_DIR/key.txt")

reset_copy() {
  PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 -d "$EV_RESTORE_DB_NAME" \
    -c 'DROP SCHEMA IF EXISTS public CASCADE' \
    -c 'CREATE SCHEMA public' \
    -c 'REVOKE ALL ON SCHEMA public FROM PUBLIC'
}

count_rows() {
  printf '%s\n' "$EV_SQL_COUNT" | psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -d "$1" -f -
}

start=$(date -u +%s)
reset_copy || fail "preparation de la base de restauration"
if [ "${RESTORE_WITH_PRIVILEGES:-false}" = "true" ]; then
  restore_flags="--exit-on-error --single-transaction"
else
  restore_flags="--no-owner --no-acl --exit-on-error --single-transaction"
fi
# shellcheck disable=SC2086 # options volontairement découpées
pg_restore $restore_flags -d "$EV_RESTORE_DB_NAME" "$WORK_DIR/dump.pgc" || fail "pg_restore"
restored_at=$(date -u +%s)

count_rows "$EV_RESTORE_DB_NAME" > "$WORK_DIR/restored.txt" || fail "comptage copie"
count_rows "$EV_DB_NAME" > "$WORK_DIR/source.txt" || fail "comptage source"

echo "== Lignes par table : copie restaurée | base source (maintenant)"
awk 'NR == FNR { r[$1] = $2; next }
     { printf "%-45s %12s %12s%s\n", $1, ($1 in r ? r[$1] : "-"), $2, (r[$1] == $2 ? "" : "  <- ecart") }' \
  "$WORK_DIR/restored.txt" "$WORK_DIR/source.txt"

tables_match=true
cut -d' ' -f1 "$WORK_DIR/restored.txt" | sort > "$WORK_DIR/t1"
cut -d' ' -f1 "$WORK_DIR/source.txt" | sort > "$WORK_DIR/t2"
cmp -s "$WORK_DIR/t1" "$WORK_DIR/t2" || tables_match=false
tables=$(wc -l < "$WORK_DIR/restored.txt")
rows=$(awk '{ s += $2 } END { print s + 0 }' "$WORK_DIR/restored.txt")
migration=$(psql -X -At -d "$EV_RESTORE_DB_NAME" \
  -c "SELECT app || '.' || name FROM django_migrations ORDER BY id DESC LIMIT 1" 2>/dev/null || echo "aucune")

cleaned=false
if [ "${KEEP_RESTORED:-false}" != "true" ]; then
  reset_copy && cleaned=true
fi
# Fichier écrit par le conteneur « download » (autre utilisateur) : effacement facultatif, le
# volume éphémère (chiffré) disparaît avec la tâche.
rm -f "$WORK_DIR/dump.pgc" 2>/dev/null || true

printf '{"event":"db_restore_test_done","key":"%s","tables":%s,"rows":%s,"last_migration":"%s","restore_seconds":%s,"tables_match":%s,"cleaned":%s}\n' \
  "$key" "$tables" "$rows" "$migration" "$((restored_at - start))" "$tables_match" "$cleaned"
[ "$tables_match" = "true" ] || fail "tables differentes entre la copie et la source"
