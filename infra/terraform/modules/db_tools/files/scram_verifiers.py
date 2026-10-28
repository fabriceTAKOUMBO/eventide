# Calcule les vérificateurs SCRAM-SHA-256 des rôles PostgreSQL à partir des mots de passe
# reçus par variables d'environnement (injectées depuis Secrets Manager), et les écrit dans
# le volume de travail de la tâche. Le script SQL envoie ensuite au serveur le vérificateur,
# jamais le mot de passe : il ne peut donc apparaître ni dans les journaux de l'instance
# (log_statement, log_min_duration_statement), ni dans pg_stat_statements.
#
# Format (RFC 5802 / RFC 7677, identique à PostgreSQL) :
#   SCRAM-SHA-256$<itérations>:<sel base64>$<StoredKey base64>:<ServerKey base64>
# Les mots de passe générés par Terraform sont alphanumériques : SASLprep les laisse tels quels.
#
# Entrée : EV_SCRAM_ROLES = "app=APP_DB_PASSWORD,migrator=MIGRATOR_DB_PASSWORD,..." (nom de
# fichier = nom de la variable). Sortie : <WORK_DIR>/<nom>.scram puis <WORK_DIR>/scram.ok.
import base64
import hashlib
import hmac
import os
import sys

ITERATIONS = 4096


def verifier(password: str) -> str:
    if not password or not password.isascii() or not password.isalnum():
        raise ValueError("mot de passe vide ou non alphanumérique (SASLprep non géré)")
    salt = os.urandom(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode("ascii"), salt, ITERATIONS)
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", "sha256").digest()

    def b64(raw: bytes) -> str:
        return base64.b64encode(raw).decode("ascii")

    return f"SCRAM-SHA-256${ITERATIONS}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def main() -> int:
    work = os.environ.get("WORK_DIR", "/work")
    pairs = [p.split("=", 1) for p in os.environ.get("EV_SCRAM_ROLES", "").split(",") if p]
    if not pairs:
        print('{"event":"db_bootstrap_failed","reason":"EV_SCRAM_ROLES vide"}')
        return 1
    os.umask(0o022)  # le conteneur psql (autre utilisateur) doit pouvoir lire les fichiers
    for name, env_var in pairs:
        try:
            value = verifier(os.environ.get(env_var, ""))
        except ValueError as exc:
            print(f'{{"event":"db_bootstrap_failed","reason":"{env_var} : {exc}"}}')
            return 1
        with open(os.path.join(work, f"{name}.scram"), "w", encoding="ascii") as fh:
            fh.write(value)
    with open(os.path.join(work, "scram.ok"), "w", encoding="ascii") as fh:
        fh.write("ok\n")
    print(f'{{"event":"db_scram_verifiers_ready","roles":{len(pairs)}}}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
