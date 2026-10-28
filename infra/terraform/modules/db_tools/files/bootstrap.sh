# Tâche <env>-db-bootstrap, conteneur « bootstrap » (client psql 16) : amorçage de la base
# et des rôles sur l'instance partagée. Précédé de lib.sh par Terraform.
set -eu
# shellcheck disable=SC2034 # lu par fail() (lib.sh, concaténé devant ce script)
FAIL_EVENT=db_bootstrap_failed

require_vars PGHOST PGPORT EV_MASTER_USER EV_MASTER_PASSWORD MIGRATOR_DB_PASSWORD \
  EV_SQL_BOOTSTRAP EV_SQL_BOOTSTRAP_CLEANUP EV_SQL_GRANTS \
  EV_APP_STATEMENT_TIMEOUT EV_APP_LOCK_TIMEOUT EV_APP_IDLE_TX_TIMEOUT \
  EV_MIGRATOR_STATEMENT_TIMEOUT EV_MIGRATOR_LOCK_TIMEOUT EV_MIGRATOR_IDLE_TX_TIMEOUT \
  EV_BACKUP_STATEMENT_TIMEOUT EV_BACKUP_LOCK_TIMEOUT EV_BACKUP_IDLE_TX_TIMEOUT \
  EV_APP_WORK_MEM EV_APP_MAINTENANCE_WORK_MEM EV_APP_TEMP_FILE_LIMIT EV_APP_IDLE_SESSION_TIMEOUT \
  EV_MIGRATOR_WORK_MEM EV_MIGRATOR_MAINTENANCE_WORK_MEM EV_MIGRATOR_TEMP_FILE_LIMIT EV_MIGRATOR_IDLE_SESSION_TIMEOUT \
  EV_BACKUP_WORK_MEM EV_BACKUP_MAINTENANCE_WORK_MEM EV_BACKUP_TEMP_FILE_LIMIT EV_BACKUP_IDLE_SESSION_TIMEOUT
require_identifiers EV_DB_NAME EV_RESTORE_DB_NAME EV_APP_ROLE EV_MIGRATOR_ROLE EV_BACKUP_ROLE
require_own_databases EV_DB_NAME EV_RESTORE_DB_NAME
require_own_roles EV_APP_ROLE EV_MIGRATOR_ROLE EV_BACKUP_ROLE
require_integers EV_APP_CONN_LIMIT EV_MIGRATOR_CONN_LIMIT EV_BACKUP_CONN_LIMIT EV_DB_CONN_LIMIT EV_RESTORE_CONN_LIMIT
require_marker scram.ok "verificateurs SCRAM absents (conteneur scram en echec)"
setup_tls

echo '{"event":"db_bootstrap_started"}'

# Script SQL lu sur l'entrée standard, exécuté avec le compte maître (base « postgres »). Le
# mot de passe passe par l'environnement de psql seul, jamais par la ligne de commande.
master_psql() {
  PGUSER="$EV_MASTER_USER" PGPASSWORD="$EV_MASTER_PASSWORD" PGDATABASE="${EV_MASTER_DATABASE:-postgres}" \
    psql -X -q -v ON_ERROR_STOP=1 -f -
}

# 1. Rôles et bases, avec le compte maître. En cas d'échec, une seconde connexion retire
# l'appartenance temporaire du compte maître à <migrator> si elle est restée
# (bootstrap_cleanup.sql), puis la tâche s'arrête en échec avec la cause d'origine.
if ! printf '%s\n' "$EV_SQL_BOOTSTRAP" | master_psql; then
  if printf '%s\n' "$EV_SQL_BOOTSTRAP_CLEANUP" | master_psql; then
    echo '{"event":"db_bootstrap_cleanup_done"}'
  else
    printf '{"event":"db_bootstrap_cleanup_failed","action":"connecte avec le compte maitre : REVOKE %s FROM CURRENT_USER"}\n' "$EV_MIGRATOR_ROLE"
  fi
  unset EV_MASTER_PASSWORD
  fail "bootstrap.sql"
fi
unset EV_MASTER_PASSWORD

# 2. Droits sur le schéma, connecté en <migrator> (le compte maître n'entre pas dans nos bases).
printf '%s\n' "$EV_SQL_GRANTS" |
  PGUSER="$EV_MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_DB_PASSWORD" PGDATABASE="$EV_DB_NAME" \
    psql -X -q -v ON_ERROR_STOP=1 -f - || fail "grants.sql"

# 3. Base de test de restauration : schéma public fermé à PUBLIC.
PGUSER="$EV_MIGRATOR_ROLE" PGPASSWORD="$MIGRATOR_DB_PASSWORD" PGDATABASE="$EV_RESTORE_DB_NAME" \
  psql -X -q -v ON_ERROR_STOP=1 -c 'REVOKE ALL ON SCHEMA public FROM PUBLIC' || fail "restore_db"

printf '{"event":"db_bootstrap_done","database":"%s","restore_database":"%s","connection_limit":%s}\n' \
  "$EV_DB_NAME" "$EV_RESTORE_DB_NAME" "$EV_DB_CONN_LIMIT"
