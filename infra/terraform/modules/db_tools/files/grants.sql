-- Droits sur le schéma public de la base applicative (idempotent), exécuté par la tâche
-- <env>-db-bootstrap connectée avec le rôle <migrator> (propriétaire de la base) : aucun
-- accès du compte maître n'est nécessaire.
--   <app>    : SELECT/INSERT/UPDATE/DELETE, séquences ; aucune DDL.
--   <backup> : lecture seule (pg_dump).
-- Les privilèges par défaut couvrent les tables et séquences créées ensuite par les
-- migrations Django (exécutées en <migrator>).

\set ON_ERROR_STOP on
\set VERBOSITY terse
\set SHOW_CONTEXT never

\getenv app_role EV_APP_ROLE
\getenv migrator_role EV_MIGRATOR_ROLE
\getenv backup_role EV_BACKUP_ROLE

REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app_role", :"backup_role";

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_role";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO :"app_role";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"backup_role";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO :"backup_role";

ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_role" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_role" IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"app_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_role" IN SCHEMA public
  GRANT SELECT ON TABLES TO :"backup_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_role" IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO :"backup_role";

SELECT current_database() AS base, n.nspname AS schema, n.nspacl::text AS droits_schema
FROM pg_namespace n WHERE n.nspname = 'public';
