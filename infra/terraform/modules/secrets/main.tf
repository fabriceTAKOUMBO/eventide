# Secrets d'Eventide dans Secrets Manager (préfixe eventide/<env>/), chiffrés par la clé KMS de
# l'environnement.
#
# - générés par Terraform : clé Django, mots de passe des rôles PostgreSQL (JSON avec l'URL de
#   connexion en TLS verify-full) ;
# - déposés à la main par le product owner (valeur provisoire « A_REMPLACER », jamais dans
#   Terraform ni les tfvars) : compte de service Google Play.
#
# Compromis assumé (comme Candidature Express) : random_password garde sa valeur dans l'état
# Terraform ; l'état est protégé par la pile bootstrap (refus explicite hors administrateurs).

locals {
  db_ssl_params = "sslmode=verify-full&sslrootcert=${urlencode(var.db_ca_bundle_path)}"
}

resource "random_password" "django_secret_key" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "django_secret_key" {
  name                    = "${var.secret_prefix}/django-secret-key"
  description             = "DJANGO_SECRET_KEY de l'API Eventide"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "django_secret_key" {
  secret_id     = aws_secretsmanager_secret.django_secret_key.id
  secret_string = random_password.django_secret_key.result
}

# --- Rôles PostgreSQL (créés sur l'instance partagée par la tâche d'amorçage db_tools) -------

resource "random_password" "db" {
  for_each = var.db_roles
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "db" {
  for_each                = var.db_roles
  name                    = "${var.secret_prefix}/db-${each.key}"
  description             = "Identifiants PostgreSQL du role ${each.value} (JSON : username, password, host, port, dbname, url)"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "db" {
  for_each  = var.db_roles
  secret_id = aws_secretsmanager_secret.db[each.key].id
  secret_string = jsonencode({
    username = each.value
    password = random_password.db[each.key].result
    host     = var.db_host
    port     = var.db_port
    dbname   = var.db_name
    url      = "postgres://${each.value}:${random_password.db[each.key].result}@${var.db_host}:${var.db_port}/${var.db_name}?${local.db_ssl_params}"
  })
}

# --- Secrets fournis par le product owner ----------------------------------------------------

resource "aws_secretsmanager_secret" "manual" {
  for_each                = var.manual_secrets
  name                    = "${var.secret_prefix}/${each.key}"
  description             = each.value
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
}

resource "aws_secretsmanager_secret_version" "manual" {
  for_each      = var.manual_secrets
  secret_id     = aws_secretsmanager_secret.manual[each.key].id
  secret_string = "A_REMPLACER"

  lifecycle {
    # La vraie valeur est déposée à la main (console ou CLI) : Terraform ne l'écrase pas.
    ignore_changes = [secret_string]
  }
}
