-- Amorçage d'Eventide sur une instance PostgreSQL PARTAGÉE (idempotent). Repris de Candidature
-- Express (même instance, même procédure), avec les rôles, la base et le marqueur d'Eventide.
--
-- Exécuté une fois (puis après chaque rotation des mots de passe) par la tâche ECS
-- <env>-db-bootstrap, avec le compte maître de l'instance, dans la base « postgres ». Le mot
-- de passe maître vient d'un secret TEMPORAIRE créé puis supprimé par le product owner
-- (docs/runbooks/premier-deploiement.md) ; il n'est jamais affiché.
--
-- Crée ou met à jour, sans rien toucher d'autre sur l'instance :
--   - les rôles <app> (DML seulement), <migrator> (propriétaire, DDL) et <backup> (lecture
--     seule, pg_dump), avec CONNECTION LIMIT et délais propres à chaque rôle ;
--   - la base <db> (propriétaire <migrator>, CONNECTION LIMIT = somme des rôles) et la base
--     de test de restauration <restore_db> ;
--   - les droits sur ces bases : plus de CONNECT pour PUBLIC.
-- Nos rôles portent le commentaire 'eventide' : un rôle du même nom sans ce
-- marqueur appartient à une autre application, et le script s'arrête sans le modifier.
-- Les mots de passe sont envoyés sous forme de vérificateurs SCRAM calculés dans la tâche
-- (scram_verifiers.py) : ils n'apparaissent dans aucun journal de l'instance.
-- Les droits sur le schéma public sont posés ensuite par grants.sql, connecté en <migrator> :
-- le compte maître n'a ainsi aucun accès permanent à nos bases.

\set ON_ERROR_STOP on
\set VERBOSITY terse
\set SHOW_CONTEXT never

\getenv db_name EV_DB_NAME
\getenv restore_db_name EV_RESTORE_DB_NAME
\getenv app_role EV_APP_ROLE
\getenv migrator_role EV_MIGRATOR_ROLE
\getenv backup_role EV_BACKUP_ROLE
\getenv app_conn_limit EV_APP_CONN_LIMIT
\getenv migrator_conn_limit EV_MIGRATOR_CONN_LIMIT
\getenv backup_conn_limit EV_BACKUP_CONN_LIMIT
\getenv db_conn_limit EV_DB_CONN_LIMIT
\getenv restore_conn_limit EV_RESTORE_CONN_LIMIT
\getenv app_statement_timeout EV_APP_STATEMENT_TIMEOUT
\getenv app_lock_timeout EV_APP_LOCK_TIMEOUT
\getenv app_idle_tx_timeout EV_APP_IDLE_TX_TIMEOUT
\getenv migrator_statement_timeout EV_MIGRATOR_STATEMENT_TIMEOUT
\getenv migrator_lock_timeout EV_MIGRATOR_LOCK_TIMEOUT
\getenv migrator_idle_tx_timeout EV_MIGRATOR_IDLE_TX_TIMEOUT
\getenv backup_statement_timeout EV_BACKUP_STATEMENT_TIMEOUT
\getenv backup_lock_timeout EV_BACKUP_LOCK_TIMEOUT
\getenv backup_idle_tx_timeout EV_BACKUP_IDLE_TX_TIMEOUT
\getenv work_dir WORK_DIR

\set app_verifier `cat "$WORK_DIR/app.scram"`
\set migrator_verifier `cat "$WORK_DIR/migrator.scram"`
\set backup_verifier `cat "$WORK_DIR/backup.scram"`

-- 0. Contexte (aucun secret).
SELECT current_user AS compte_admin,
       current_setting('server_version') AS version_serveur,
       current_setting('max_connections') AS max_connections,
       (SELECT count(*) FROM pg_stat_activity) AS connexions_en_cours;

-- Garde-fou : des vérificateurs SCRAM sont attendus, jamais des mots de passe en clair.
SELECT (:'app_verifier' LIKE 'SCRAM-SHA-256$%'
        AND :'migrator_verifier' LIKE 'SCRAM-SHA-256$%'
        AND :'backup_verifier' LIKE 'SCRAM-SHA-256$%') AS verificateurs_ok \gset
\if :verificateurs_ok
\else
  \echo '{"event":"db_bootstrap_failed","reason":"verificateurs SCRAM invalides"}'
  SELECT 1/0 AS arret;
\endif

-- 1. Rôles. Chaque rôle créé ici porte le marqueur COMMENT ON ROLE … IS 'eventide'.
-- Un rôle du même nom qui existe SANS ce marqueur n'a pas été créé par cet amorçage (autre
-- application de l'instance) : arrêt immédiat, sans rien modifier (ni mot de passe, ni
-- limites, ni droits).
\set role_marker 'eventide'

SELECT count(*) = 0 AS roles_ok,
       coalesce(string_agg(p.rolname, ', ' ORDER BY p.rolname), '') AS roles_etrangers
FROM pg_roles p
WHERE p.rolname IN (:'migrator_role', :'app_role', :'backup_role')
  AND shobj_description(p.oid, 'pg_authid') IS DISTINCT FROM :'role_marker' \gset
\if :roles_ok
\else
  \echo '{"event":"db_bootstrap_failed","reason":"role existant sans le marqueur eventide, non cree par cet amorcage : ' :roles_etrangers '"}'
  SELECT 1/0 AS arret;
\endif

-- Création (sans connexion, puis complétée) et marqueur dans la même transaction.
-- SUPERUSER, REPLICATION et BYPASSRLS ne sont pas cités : désactivés à la création, et le
-- compte maître RDS (non superutilisateur) n'a pas le droit de les mentionner.
BEGIN;
SELECT format('CREATE ROLE %I NOLOGIN', r), format('COMMENT ON ROLE %I IS %L', r, :'role_marker')
FROM unnest(ARRAY[:'migrator_role', :'app_role', :'backup_role']) AS t(r)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = t.r) \gexec
COMMIT;

ALTER ROLE :"migrator_role" WITH LOGIN NOCREATEDB NOCREATEROLE
  CONNECTION LIMIT :migrator_conn_limit PASSWORD :'migrator_verifier';
ALTER ROLE :"app_role" WITH LOGIN NOCREATEDB NOCREATEROLE
  CONNECTION LIMIT :app_conn_limit PASSWORD :'app_verifier';
ALTER ROLE :"backup_role" WITH LOGIN NOCREATEDB NOCREATEROLE
  CONNECTION LIMIT :backup_conn_limit PASSWORD :'backup_verifier';

-- Délais par rôle : une requête ou une transaction oubliée de notre application ne peut pas
-- monopoliser l'instance partagée.
ALTER ROLE :"app_role" SET statement_timeout = :'app_statement_timeout';
ALTER ROLE :"app_role" SET lock_timeout = :'app_lock_timeout';
ALTER ROLE :"app_role" SET idle_in_transaction_session_timeout = :'app_idle_tx_timeout';
ALTER ROLE :"migrator_role" SET statement_timeout = :'migrator_statement_timeout';
ALTER ROLE :"migrator_role" SET lock_timeout = :'migrator_lock_timeout';
ALTER ROLE :"migrator_role" SET idle_in_transaction_session_timeout = :'migrator_idle_tx_timeout';
ALTER ROLE :"backup_role" SET statement_timeout = :'backup_statement_timeout';
ALTER ROLE :"backup_role" SET lock_timeout = :'backup_lock_timeout';
ALTER ROLE :"backup_role" SET idle_in_transaction_session_timeout = :'backup_idle_tx_timeout';

-- Le compte maître doit pouvoir agir en tant que <migrator> pour créer les bases à son nom
-- (PostgreSQL 16). Appartenance temporaire, retirée en fin de script ; en cas d'échec avant
-- la fin, bootstrap.sh la retire par un second appel (bootstrap_cleanup.sql).
GRANT :"migrator_role" TO CURRENT_USER WITH SET TRUE, INHERIT FALSE;

-- 2. Bases (propriétaire <migrator>).
SELECT format('CREATE DATABASE %I OWNER %I CONNECTION LIMIT %s', :'db_name', :'migrator_role', :db_conn_limit)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name') \gexec
SELECT format('CREATE DATABASE %I OWNER %I CONNECTION LIMIT %s', :'restore_db_name', :'migrator_role', :restore_conn_limit)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'restore_db_name') \gexec

SET ROLE :"migrator_role";
ALTER DATABASE :"db_name" CONNECTION LIMIT :db_conn_limit;
ALTER DATABASE :"restore_db_name" CONNECTION LIMIT :restore_conn_limit;
-- Plus de CONNECT par défaut (PUBLIC) : seuls nos rôles entrent dans nos bases.
REVOKE ALL ON DATABASE :"db_name" FROM PUBLIC;
REVOKE ALL ON DATABASE :"restore_db_name" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"db_name" TO :"app_role";
GRANT CONNECT ON DATABASE :"db_name" TO :"backup_role";
RESET ROLE;

REVOKE :"migrator_role" FROM CURRENT_USER;

-- 3. Contrôle lisible dans les journaux de la tâche (aucun secret).
SELECT r.rolname AS role, r.rolcanlogin AS connexion, r.rolsuper AS superutilisateur,
       r.rolcreaterole AS cree_roles, r.rolcreatedb AS cree_bases, r.rolconnlimit AS limite,
       coalesce(array_to_string(s.setconfig, ' '), '') AS reglages
FROM pg_roles r
LEFT JOIN pg_db_role_setting s ON s.setrole = r.oid AND s.setdatabase = 0
WHERE r.rolname IN (:'app_role', :'migrator_role', :'backup_role')
ORDER BY r.rolname;

SELECT d.datname AS base, pg_get_userbyid(d.datdba) AS proprietaire, d.datconnlimit AS limite,
       d.datacl::text AS droits
FROM pg_database d
WHERE d.datname IN (:'db_name', :'restore_db_name')
ORDER BY d.datname;
