#!/usr/bin/env bash
# Test des scripts d'amorçage, de sauvegarde et de restauration (modules/db_tools/files) contre
# un vrai PostgreSQL 16, sans AWS et sans Docker : une instance jetable (initdb) lancée avec les
# binaires locaux (PG_BIN, par défaut /usr/lib/postgresql/16/bin, présents sur le runner GitHub
# ubuntu-24.04 et installables par apt). Adapté de Candidature Express (même scénario, mêmes
# contrôles), qui utilise des conteneurs.
#
# Le « compte maître » est simulé comme sur RDS : un rôle NON superutilisateur avec CREATEROLE
# et CREATEDB (rds_superuser n'est pas superutilisateur). Le serveur journalise toutes les
# requêtes (log_statement = all) pour prouver qu'aucun mot de passe n'y apparaît. Une
# « autre application » (rôle cinaf_app, base appdb) occupe déjà l'instance.
#
# Facultatif : API_CHECK=true joue aussi les migrations Django d'Eventide avec ev_migrator puis
# écrit avec ev_app (privilèges par défaut), via `uv` dans backend/.
#
# Usage : bash infra/terraform/modules/db_tools/tests/run-local.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
files="$here/../files"
repo="$(cd "$here/../../../../.." && pwd)"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/16/bin}"
PORT="${PG_TEST_PORT:-55499}"
export PATH="$PG_BIN:$PATH"

[ -x "$PG_BIN/initdb" ] || { echo "ECHEC initdb introuvable dans $PG_BIN (PostgreSQL 16)"; exit 1; }
"$PG_BIN/postgres" --version | grep -q ' 16\.' || { echo "ECHEC PostgreSQL 16 attendu"; exit 1; }

pass() { (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40); }
SUPER_PW=$(pass); MASTER_PW=$(pass); APP_PW=$(pass); MIG_PW=$(pass); BAK_PW=$(pass); OTHER_PW=$(pass); NODB_PW=$(pass)

root="$(mktemp -d)"
data="$root/data"
work="$root/work"
log="$root/server.log"
mkdir -p "$work"

# initdb refuse de tourner en root : l'instance appartient alors à l'utilisateur postgres.
as_server() {
  if [ "$(id -u)" = "0" ]; then runuser -u postgres -- "$@"; else "$@"; fi
}
if [ "$(id -u)" = "0" ]; then chown postgres "$root"; chmod 700 "$root"; touch "$log"; chown postgres "$log"; fi

cleanup() {
  as_server "$PG_BIN/pg_ctl" -D "$data" -m immediate stop > /dev/null 2>&1 || true
  rm -rf "$root"
}
trap cleanup EXIT

ok() { printf 'OK   %s\n' "$1"; }
ko() { printf 'ECHEC %s\n' "$1"; exit 1; }

printf '%s\n' "$SUPER_PW" > "$root/pw"
[ "$(id -u)" = "0" ] && chown postgres "$root/pw"
as_server "$PG_BIN/initdb" -D "$data" -U postgres --pwfile="$root/pw" --auth-local=scram-sha-256 \
  --auth-host=scram-sha-256 -E UTF8 --locale=C.UTF-8 > /dev/null
rm -f "$root/pw"
as_server "$PG_BIN/pg_ctl" -D "$data" -l "$log" -w -o \
  "-p $PORT -k $root -c listen_addresses=127.0.0.1 -c log_statement=all -c password_encryption=scram-sha-256" \
  start > /dev/null

# psql en TCP avec mot de passe : <utilisateur> <mot de passe> <base> [args...]
psql_as() {
  local user="$1" pw="$2" db="$3"
  shift 3
  PGPASSWORD="$pw" psql -X -q -h 127.0.0.1 -p "$PORT" -U "$user" -d "$db" -v ON_ERROR_STOP=1 "$@"
}

psql_as postgres "$SUPER_PW" postgres -c "SET log_statement = 'none'" \
  -c "CREATE ROLE app_admin LOGIN CREATEROLE CREATEDB PASSWORD '$MASTER_PW'" \
  -c "CREATE ROLE cinaf_app LOGIN PASSWORD '$OTHER_PW'" -c "CREATE DATABASE appdb OWNER app_admin"
ok "instance de test prête (PostgreSQL 16, app_admin non superutilisateur, autre application présente)"

# Variables communes aux conteneurs de la tâche ECS (comme le définit modules/db_tools/main.tf).
common_env=(
  PGHOST=127.0.0.1 PGPORT="$PORT" PGSSLMODE=disable RDS_CA_URL= WORK_DIR="$work" HOME="$work"
  EV_DB_NAME=eventide EV_RESTORE_DB_NAME=eventide_restore
  EV_APP_ROLE=ev_app EV_MIGRATOR_ROLE=ev_migrator EV_BACKUP_ROLE=ev_backup
)

# Arguments facultatifs : NOM=valeur qui remplacent les valeurs par défaut.
run_bootstrap() {
  rm -rf "${work:?}"/* && touch "$work/init.ok"
  env -i PATH="$PATH" EV_SCRAM_ROLES="app=APP_DB_PASSWORD,migrator=MIGRATOR_DB_PASSWORD,backup=BACKUP_DB_PASSWORD" \
    WORK_DIR="$work" APP_DB_PASSWORD="$APP_PW" MIGRATOR_DB_PASSWORD="$MIG_PW" BACKUP_DB_PASSWORD="$BAK_PW" \
    python3 -I -c "$(cat "$files/scram_verifiers.py")"
  env -i PATH="$PATH" "${common_env[@]}" \
    EV_MASTER_USER=app_admin EV_MASTER_PASSWORD="$MASTER_PW" EV_MASTER_DATABASE=postgres \
    MIGRATOR_DB_PASSWORD="$MIG_PW" \
    EV_APP_CONN_LIMIT=10 EV_MIGRATOR_CONN_LIMIT=2 EV_BACKUP_CONN_LIMIT=2 EV_DB_CONN_LIMIT=14 EV_RESTORE_CONN_LIMIT=2 \
    EV_APP_STATEMENT_TIMEOUT=30s EV_APP_LOCK_TIMEOUT=5s EV_APP_IDLE_TX_TIMEOUT=60s \
    EV_MIGRATOR_STATEMENT_TIMEOUT=15min EV_MIGRATOR_LOCK_TIMEOUT=10s EV_MIGRATOR_IDLE_TX_TIMEOUT=5min \
    EV_BACKUP_STATEMENT_TIMEOUT=0 EV_BACKUP_LOCK_TIMEOUT=60s EV_BACKUP_IDLE_TX_TIMEOUT=10min \
    EV_APP_WORK_MEM=4MB EV_APP_MAINTENANCE_WORK_MEM=16MB EV_APP_TEMP_FILE_LIMIT=256MB EV_APP_IDLE_SESSION_TIMEOUT=15min \
    EV_MIGRATOR_WORK_MEM=16MB EV_MIGRATOR_MAINTENANCE_WORK_MEM=64MB EV_MIGRATOR_TEMP_FILE_LIMIT=1GB EV_MIGRATOR_IDLE_SESSION_TIMEOUT=10min \
    EV_BACKUP_WORK_MEM=4MB EV_BACKUP_MAINTENANCE_WORK_MEM=16MB EV_BACKUP_TEMP_FILE_LIMIT=256MB EV_BACKUP_IDLE_SESSION_TIMEOUT=10min \
    EV_SQL_BOOTSTRAP="$(cat "$files/bootstrap.sql")" EV_SQL_GRANTS="$(cat "$files/grants.sql")" \
    EV_SQL_BOOTSTRAP_CLEANUP="$(cat "$files/bootstrap_cleanup.sql")" \
    "$@" \
    sh -c "$(cat "$files/lib.sh" "$files/bootstrap.sh")"
}

echo "== Amorçage (1er passage : compte maître sans droit SET sur temp_file_limit)"
out=$(run_bootstrap 2>&1) || { echo "$out"; ko "amorçage"; }
grep -q '"event":"db_bootstrap_temp_file_limit_skipped"' <<< "$out" || { echo "$out"; ko "absence du droit SET sur temp_file_limit non signalée"; }
ok "amorçage terminé (temp_file_limit signalé, non posé)"
# RDS : le compte maître peut avoir le droit SET sur temp_file_limit (non vérifié) ; simulé ici.
psql_as postgres "$SUPER_PW" postgres -c "GRANT SET ON PARAMETER temp_file_limit TO app_admin" > /dev/null
echo "== Amorçage (2e passage : idempotence, nouveaux vérificateurs, droit SET sur temp_file_limit)"
out=$(run_bootstrap 2>&1) || { echo "$out"; ko "amorçage relancé"; }
if grep -q 'db_bootstrap_temp_file_limit_skipped' <<< "$out"; then ko "temp_file_limit non posé malgré le droit SET"; fi
ok "amorçage relancé sans erreur"

# Migration simulée (rôle propriétaire), puis droits du rôle applicatif.
psql_as ev_migrator "$MIG_PW" eventide \
  -c "CREATE TABLE django_migrations (id bigserial PRIMARY KEY, app text, name text, applied timestamptz DEFAULT now())" \
  -c "INSERT INTO django_migrations (app, name) VALUES ('installations', '0001_initial')" \
  -c "CREATE TABLE installations_installation (id bigserial PRIMARY KEY, device_hash text NOT NULL)"
ok "ev_migrator : DDL dans sa base"

psql_as ev_app "$APP_PW" eventide \
  -c "INSERT INTO installations_installation (device_hash) VALUES ('a'), ('b')" \
  -c "UPDATE installations_installation SET device_hash = upper(device_hash)" -c "SELECT count(*) FROM installations_installation" > /dev/null
ok "ev_app : DML sur les tables créées par les migrations (privilèges par défaut)"

if psql_as ev_app "$APP_PW" eventide -c "CREATE TABLE pirate (id int)" > /dev/null 2>&1; then ko "ev_app a pu créer une table"; fi
ok "ev_app : aucune DDL"

if psql_as ev_backup "$BAK_PW" eventide -c "DELETE FROM installations_installation" > /dev/null 2>&1; then ko "ev_backup a pu écrire"; fi
ok "ev_backup : lecture seule"

for who in "app_admin:$MASTER_PW" "cinaf_app:$OTHER_PW"; do
  if psql_as "${who%%:*}" "${who#*:}" eventide -c "SELECT 1" > /dev/null 2>&1; then ko "${who%%:*} entre dans eventide"; fi
done
ok "ni le compte maître ni une autre application n'entrent dans eventide (CONNECT retiré à PUBLIC)"

settings=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT r.rolname || ' ' || r.rolconnlimit || ' ' || array_to_string(s.setconfig, ',') FROM pg_roles r JOIN pg_db_role_setting s ON s.setrole = r.oid WHERE r.rolname LIKE 'ev\_%' ORDER BY 1")
echo "$settings"
echo "$settings" | grep -q "ev_app 10 .*statement_timeout=30s" || ko "réglages de ev_app"
echo "$settings" | grep -q "ev_migrator 2 .*lock_timeout=10s" || ko "réglages de ev_migrator"
echo "$settings" | grep -q "ev_backup 2 .*idle_in_transaction_session_timeout=10min" || ko "réglages de ev_backup"
dblimit=$(psql_as postgres "$SUPER_PW" postgres -At -c "SELECT datconnlimit FROM pg_database WHERE datname = 'eventide'")
[ "$dblimit" = "14" ] || ko "limite de connexions de la base ($dblimit)"
ok "limites de connexions (10 / 2 / 2, base 14) et délais par rôle"

echo "$settings" | grep -q "ev_app 10 .*work_mem=4MB.*maintenance_work_mem=16MB.*idle_session_timeout=15min.*max_parallel_workers_per_gather=0.*max_parallel_maintenance_workers=0.*temp_file_limit=256MB" || ko "plafonds de ressources de ev_app"
echo "$settings" | grep -q "ev_migrator 2 .*work_mem=16MB.*maintenance_work_mem=64MB.*idle_session_timeout=10min.*max_parallel_workers_per_gather=0.*temp_file_limit=1GB" || ko "plafonds de ressources de ev_migrator"
echo "$settings" | grep -q "ev_backup 2 .*work_mem=4MB.*idle_session_timeout=10min.*max_parallel_workers_per_gather=0.*temp_file_limit=256MB" || ko "plafonds de ressources de ev_backup"
effective=$(psql_as ev_app "$APP_PW" eventide -At -c \
  "SELECT string_agg(name || '=' || setting, ' ' ORDER BY name) FROM pg_settings WHERE name IN ('work_mem', 'temp_file_limit', 'idle_session_timeout', 'max_parallel_workers_per_gather')")
[ "$effective" = "idle_session_timeout=900000 max_parallel_workers_per_gather=0 temp_file_limit=262144 work_mem=4096" ] || ko "plafonds effectifs de ev_app ($effective)"
if psql_as ev_app "$APP_PW" eventide -c "SET temp_file_limit = '10GB'" > /dev/null 2>&1; then ko "ev_app a relevé son temp_file_limit"; fi
ok "plafonds par rôle (work_mem, maintenance_work_mem, temp_file_limit, idle_session_timeout, aucun worker parallèle) ; temp_file_limit non relevable"

member=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE r.rolname = 'ev_migrator' AND u.rolname = 'app_admin' AND m.set_option")
[ "$member" = "0" ] || ko "le compte maître garde SET sur ev_migrator"
ok "appartenance temporaire du compte maître retirée"

markers=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT count(*) FROM pg_roles WHERE rolname IN ('ev_app', 'ev_migrator', 'ev_backup') AND shobj_description(oid, 'pg_authid') = 'eventide'")
[ "$markers" = "3" ] || ko "marqueur eventide absent ($markers rôle(s) sur 3)"
ok "nos rôles portent le marqueur eventide"

echo "== Amorçage refusé : nom de rôle ou de base hors des préfixes d'Eventide"
if out=$(run_bootstrap EV_APP_ROLE=cinaf_app 2>&1); then echo "$out"; ko "l'amorçage a accepté le rôle cinaf_app"; fi
grep -q 'role EV_APP_ROLE hors d' <<< "$out" || { echo "$out"; ko "motif du refus (nom de rôle) absent"; }
if out=$(run_bootstrap EV_DB_NAME=appdb 2>&1); then echo "$out"; ko "l'amorçage a accepté la base appdb"; fi
grep -q 'base EV_DB_NAME hors d' <<< "$out" || { echo "$out"; ko "motif du refus (nom de base) absent"; }
foreign=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT rolconnlimit || ' ' || coalesce(shobj_description(oid, 'pg_authid'), 'sans-commentaire') FROM pg_roles WHERE rolname = 'cinaf_app'")
[ "$foreign" = "-1 sans-commentaire" ] || ko "le rôle étranger a été modifié ($foreign)"
ok "noms hors d'Eventide refusés avant toute connexion"

echo "== Amorçage refusé : rôle ev_* du même nom créé par une autre application (sans marqueur)"
psql_as postgres "$SUPER_PW" postgres -c "SET log_statement = 'none'" -c "CREATE ROLE ev_foreign LOGIN PASSWORD '$OTHER_PW'" > /dev/null
if out=$(run_bootstrap EV_APP_ROLE=ev_foreign 2>&1); then echo "$out"; ko "l'amorçage a accepté un rôle étranger"; fi
grep -q 'non cree par cet amorcage : .*ev_foreign' <<< "$out" || { echo "$out"; ko "motif du refus absent des journaux"; }
foreign=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT r.rolconnlimit || ' ' || coalesce(shobj_description(r.oid, 'pg_authid'), 'sans-commentaire') || ' ' || (SELECT count(*) FROM pg_db_role_setting s WHERE s.setrole = r.oid) FROM pg_roles r WHERE r.rolname = 'ev_foreign'")
[ "$foreign" = "-1 sans-commentaire 0" ] || ko "le rôle étranger a été modifié ($foreign)"
psql_as ev_foreign "$OTHER_PW" postgres -c "SELECT 1" > /dev/null || ko "mot de passe du rôle étranger modifié"
ok "rôle étranger laissé intact, amorçage arrêté"

echo "== Amorçage refusé : base eventide_* qui appartient à une autre application"
psql_as postgres "$SUPER_PW" postgres -c "CREATE DATABASE eventide_other OWNER app_admin CONNECTION LIMIT -1" > /dev/null
if out=$(run_bootstrap EV_APP_ROLE=ev_o_app EV_MIGRATOR_ROLE=ev_o_migrator EV_BACKUP_ROLE=ev_o_backup \
  EV_DB_NAME=eventide_other EV_RESTORE_DB_NAME=eventide_other_restore 2>&1); then echo "$out"; ko "l'amorçage a accepté une base étrangère"; fi
grep -q "proprietaire n est pas notre role de migration : .*eventide_other" <<< "$out" || { echo "$out"; ko "motif du refus (base étrangère) absent"; }
state=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT (SELECT datconnlimit || ' ' || pg_get_userbyid(datdba) || ' ' || coalesce(datacl::text, 'acl-defaut') FROM pg_database WHERE datname = 'eventide_other') || ' ' || (SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ev\_o\_%') || ' ' || (SELECT count(*) FROM pg_database WHERE datname = 'eventide_other_restore')")
[ "$state" = "-1 app_admin acl-defaut 0 0" ] || ko "la base étrangère ou l'instance a été modifiée ($state)"
ok "base étrangère laissée intacte, aucun rôle ni base créés"

echo "== Échec après l'appartenance temporaire : nettoyage (compte maître sans CREATEDB)"
psql_as postgres "$SUPER_PW" postgres -c "SET log_statement = 'none'" -c "CREATE ROLE app_admin_nodb LOGIN CREATEROLE PASSWORD '$NODB_PW'" > /dev/null
if out=$(run_bootstrap EV_MASTER_USER=app_admin_nodb EV_MASTER_PASSWORD="$NODB_PW" \
  EV_APP_ROLE=ev_t_app EV_MIGRATOR_ROLE=ev_t_migrator EV_BACKUP_ROLE=ev_t_backup \
  EV_DB_NAME=eventide_t EV_RESTORE_DB_NAME=eventide_t_restore 2>&1); then echo "$out"; ko "l'amorçage sans CREATEDB a réussi"; fi
grep -q '"event":"db_bootstrap_cleanup_done"' <<< "$out" || { echo "$out"; ko "nettoyage non signalé"; }
grep -q '"event":"db_bootstrap_failed","reason":"bootstrap.sql"' <<< "$out" || { echo "$out"; ko "cause d'origine non signalée"; }
left=$(psql_as postgres "$SUPER_PW" postgres -At -c \
  "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE r.rolname = 'ev_t_migrator' AND u.rolname = 'app_admin_nodb' AND m.set_option")
[ "$left" = "0" ] || ko "le compte maître garde SET sur ev_t_migrator après l'échec"
ok "échec de l'amorçage : appartenance temporaire retirée par le nettoyage"

backup() { # sauvegarde de eventide par ev_backup dans $work/dump.pgc
  rm -rf "${work:?}"/* && touch "$work/init.ok"
  env -i PATH="$PATH" PGHOST=127.0.0.1 PGPORT="$PORT" PGSSLMODE=disable RDS_CA_URL= WORK_DIR="$work" \
    PGDATABASE=eventide PGUSER=ev_backup PGPASSWORD="$BAK_PW" \
    sh -c "$(cat "$files/lib.sh" "$files/backup_dump.sh")"
}
restore() { # restore_test.sh, NOM=valeur en surcharge
  printf 'test/dump.pgc' > "$work/key.txt" && touch "$work/download.ok"
  env -i PATH="$PATH" "${common_env[@]}" MIGRATOR_DB_PASSWORD="$MIG_PW" EV_SQL_COUNT="$(cat "$files/count_rows.sql")" "$@" \
    sh -c "$(cat "$files/lib.sh" "$files/restore_test.sh")"
}

echo "== Sauvegarde (pg_dump, rôle ev_backup)"
backup
ok "sauvegarde produite et relue"

echo "== Sauvegarde et restauration refusées hors des bases d'Eventide"
rm -rf "${work:?}"/* && touch "$work/init.ok"
if out=$(env -i PATH="$PATH" PGHOST=127.0.0.1 PGPORT="$PORT" PGSSLMODE=disable RDS_CA_URL= WORK_DIR="$work" \
  PGDATABASE=appdb PGUSER=ev_backup PGPASSWORD="$BAK_PW" sh -c "$(cat "$files/lib.sh" "$files/backup_dump.sh")" 2>&1); then
  echo "$out"; ko "sauvegarde d'une base étrangère acceptée"
fi
grep -q 'base PGDATABASE hors d' <<< "$out" || { echo "$out"; ko "motif du refus (sauvegarde) absent"; }
[ ! -f "$work/dump.pgc" ] || ko "un fichier de sauvegarde a été produit"
if out=$(restore EV_RESTORE_DB_NAME=appdb 2>&1); then echo "$out"; ko "restauration dans une base étrangère acceptée"; fi
grep -q 'base EV_RESTORE_DB_NAME hors d' <<< "$out" || { echo "$out"; ko "motif du refus (restauration) absent"; }
ok "aucune sauvegarde ni restauration possible hors des bases d'Eventide"
backup > /dev/null

echo "== Test de restauration (base eventide_restore)"
restore
left=$(psql_as ev_migrator "$MIG_PW" eventide_restore -At -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
[ "$left" = "0" ] || ko "la copie restaurée n'a pas été vidée"
ok "restauration vérifiée puis copie vidée"

echo "== Restauration en place (procédure d'incident : droits et privilèges par défaut compris)"
backup > /dev/null
psql_as ev_app "$APP_PW" eventide -c "DELETE FROM installations_installation" > /dev/null
restore EV_RESTORE_DB_NAME=eventide KEEP_RESTORED=true RESTORE_WITH_PRIVILEGES=true > /dev/null
back=$(psql_as ev_app "$APP_PW" eventide -At -c "SELECT count(*) FROM installations_installation")
[ "$back" = "2" ] || ko "restauration en place : $back ligne(s) au lieu de 2"
psql_as ev_migrator "$MIG_PW" eventide -c "CREATE TABLE apres_incident (id bigserial PRIMARY KEY)" > /dev/null
psql_as ev_app "$APP_PW" eventide -c "INSERT INTO apres_incident DEFAULT VALUES" > /dev/null ||
  ko "privilèges par défaut perdus après la restauration en place"
psql_as ev_backup "$BAK_PW" eventide -c "SELECT count(*) FROM apres_incident" > /dev/null ||
  ko "droits de ev_backup perdus après la restauration en place"
if psql_as cinaf_app "$OTHER_PW" eventide -c "SELECT 1" > /dev/null 2>&1; then ko "PUBLIC a retrouvé CONNECT"; fi
ok "restauration en place : données, droits et privilèges par défaut rétablis"

if [ "${API_CHECK:-false}" = "true" ]; then
  echo "== Migrations Django d'Eventide (ev_migrator) puis écriture par l'API (ev_app)"
  psql_as ev_migrator "$MIG_PW" eventide -c "DROP TABLE apres_incident, installations_installation, django_migrations" > /dev/null
  api() { # <rôle> <mot de passe> <args manage.py...>
    local user="$1" pw="$2"
    shift 2
    (cd "$repo/backend" && env DJANGO_SETTINGS_MODULE=config.settings.dev DJANGO_READ_DOT_ENV=false \
      DJANGO_SECRET_KEY="local-check-$(pass)" DB_POOL_MAX_SIZE=0 \
      DATABASE_URL="postgres://$user:$pw@127.0.0.1:$PORT/eventide?sslmode=disable" \
      uv run --frozen python manage.py "$@")
  }
  api ev_migrator "$MIG_PW" migrate --noinput > /dev/null || ko "migrate sous ev_migrator"
  api ev_app "$APP_PW" shell -c "
from apps.installations.views import register
installation, token = register('ab' * 32, '1.0.0')
from apps.shares.models import Share
from apps.core import ratelimit
Share.objects.create(code='chk00001', scene={'version': 1}, installation=installation)
ratelimit.hit('check', 'k', limit=5, window_seconds=60)
print('ok')" | grep -q ok || ko "écriture par ev_app après les migrations"
  backup > /dev/null
  restore > /dev/null || ko "sauvegarde et restauration après les migrations Django"
  ok "migrations Django (ev_migrator), écritures (ev_app), sauvegarde et restauration du vrai schéma"

  # Pooled connection (as in production, DB_POOL_MAX_SIZE > 0) closed by the server, as
  # idle_session_timeout does on the shared instance: the next query must get a new connection
  # (CONN_HEALTH_CHECKS), not an error.
  echo "== Pool de l'API : connexion fermée par le serveur (idle_session_timeout), remplacée"
  pool_out=$(cd "$repo/backend" && env DJANGO_SETTINGS_MODULE=config.settings.dev DJANGO_READ_DOT_ENV=false \
    DJANGO_SECRET_KEY="local-check-$(pass)" DB_POOL_MAX_SIZE=1 \
    DATABASE_URL="postgres://ev_app:$APP_PW@127.0.0.1:$PORT/eventide?sslmode=disable" \
    SUPER_DSN="postgres://postgres:$SUPER_PW@127.0.0.1:$PORT/postgres?sslmode=disable" \
    uv run --frozen python manage.py shell -c "
import os, time, psycopg
from django.db import connection
with connection.cursor() as c:
    c.execute('SELECT pg_backend_pid()')
    first = c.fetchone()[0]
connection.close()
with psycopg.connect(os.environ['SUPER_DSN'], autocommit=True) as s:
    s.execute('SELECT pg_terminate_backend(%s)', [first])
time.sleep(0.5)
with connection.cursor() as c:
    c.execute('SELECT pg_backend_pid()')
    second = c.fetchone()[0]
print('pool-ok' if second != first else 'pool-same')" 2>&1) || true
  grep -q pool-ok <<< "$pool_out" || { echo "$pool_out"; ko "connexion du pool fermée par le serveur non remplacée"; }
  ok "pool de l'API : une connexion fermée par le serveur est remplacée avant usage"
fi

echo "== Journaux du serveur (log_statement = all)"
logs=$(cat "$log")
for secret in "$APP_PW" "$MIG_PW" "$BAK_PW" "$MASTER_PW" "$NODB_PW"; do
  if grep -qF -- "$secret" <<< "$logs"; then ko "un mot de passe apparaît dans les journaux du serveur"; fi
done
grep -q "SCRAM-SHA-256" <<< "$logs" || ko "vérificateurs SCRAM absents des journaux (test non probant)"
ok "aucun mot de passe dans les journaux : seuls des vérificateurs SCRAM ont été envoyés"

echo "Tous les contrôles sont verts."
