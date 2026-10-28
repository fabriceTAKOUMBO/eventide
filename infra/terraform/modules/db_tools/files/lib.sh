# shellcheck shell=sh
# Fonctions communes des tâches d'administration PostgreSQL (amorçage, sauvegarde,
# restauration). Concaténé devant chaque script par Terraform. Aucune fonction n'affiche de
# secret : les messages sont des lignes JSON avec une clé "event".

WORK_DIR="${WORK_DIR:-/work}"

fail() {
  printf '{"event":"%s","reason":"%s"}\n' "${FAIL_EVENT:-db_tool_failed}" "$1"
  exit 1
}

# Variables obligatoires (noms passés en arguments) : présentes et non vides.
require_vars() {
  for _name in "$@"; do
    eval "_value=\${$_name:-}"
    [ -n "$_value" ] || fail "variable $_name absente"
  done
}

# Identifiants PostgreSQL (bases, rôles) : minuscules, chiffres, tirets bas.
require_identifiers() {
  for _name in "$@"; do
    eval "_value=\${$_name:-}"
    case "$_value" in
      "" | *[!a-z0-9_]* | [!a-z_]*) fail "identifiant $_name invalide" ;;
    esac
  done
}

# Shared instance (CINAF, JobMinutes, Candidature Express): Eventide only ever names its own
# databases (eventide, eventide_*) and roles (ev_*), whatever overrides a task run receives.
# Call after require_identifiers.
require_own_databases() {
  for _name in "$@"; do
    eval "_value=\${$_name:-}"
    case "$_value" in
      eventide | eventide_*) ;;
      *) fail "base $_name hors d'Eventide (eventide ou eventide_* attendu)" ;;
    esac
  done
}

require_own_roles() {
  for _name in "$@"; do
    eval "_value=\${$_name:-}"
    case "$_value" in
      ev_?*) ;;
      *) fail "role $_name hors d'Eventide (ev_* attendu)" ;;
    esac
  done
}

require_integers() {
  for _name in "$@"; do
    eval "_value=\${$_name:-}"
    case "$_value" in
      "" | *[!0-9]*) fail "entier $_name invalide" ;;
    esac
  done
}

# TLS : sslmode=verify-full avec le bundle d'autorités de certification RDS, téléchargé puis
# vérifié par empreinte (même empreinte que backend/Dockerfile). RDS_CA_URL vide : le mode
# reste celui de PGSSLMODE (tests locaux sans TLS).
setup_tls() {
  if [ -n "${RDS_CA_URL:-}" ]; then
    require_vars RDS_CA_SHA256
    wget -q -T 30 -O "$WORK_DIR/rds-ca.pem" "$RDS_CA_URL" || fail "rds_ca_download"
    echo "$RDS_CA_SHA256  $WORK_DIR/rds-ca.pem" | sha256sum -c -s - || fail "rds_ca_checksum"
    PGSSLROOTCERT="$WORK_DIR/rds-ca.pem"
    PGSSLMODE=verify-full
    export PGSSLROOTCERT PGSSLMODE
  fi
}

# Attend le fichier témoin écrit par le conteneur précédent (dépendance COMPLETE : il peut
# avoir échoué).
require_marker() {
  [ -f "$WORK_DIR/$1" ] || fail "$2"
}
