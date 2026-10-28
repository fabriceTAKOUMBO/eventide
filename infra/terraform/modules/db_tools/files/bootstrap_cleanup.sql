-- Nettoyage après un ÉCHEC de bootstrap.sql (idempotent), exécuté par bootstrap.sh avec le
-- compte maître, dans une seconde connexion.
--
-- bootstrap.sql donne au compte maître une appartenance TEMPORAIRE à <migrator>
-- (GRANT … WITH SET TRUE) et la retire à la fin. S'il s'arrête entre les deux (création de base
-- refusée, coupure…), ce script la retire : le compte maître ne garde aucun moyen d'agir en
-- tant que <migrator>. Il ne touche qu'une appartenance accordée par le compte maître
-- lui-même, et seulement sur un rôle qui porte notre marqueur 'eventide'.
-- Aucune action si l'appartenance n'existe pas (échec avant le GRANT, rôle étranger).

\set ON_ERROR_STOP on
\set VERBOSITY terse
\set SHOW_CONTEXT never

\getenv migrator_role EV_MIGRATOR_ROLE
\set role_marker 'eventide'

SELECT format('REVOKE %I FROM CURRENT_USER', r.rolname)
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.roleid
JOIN pg_roles u ON u.oid = m.member
WHERE r.rolname = :'migrator_role'
  AND u.rolname = current_user
  AND m.grantor = m.member
  AND shobj_description(r.oid, 'pg_authid') = :'role_marker' \gexec

-- Contrôle : plus aucune appartenance avec SET du compte maître sur notre <migrator>. Sinon,
-- échec du nettoyage (bootstrap.sh l'affiche avec la commande à lancer à la main).
SELECT count(*) = 0 AS nettoyage_ok
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.roleid
JOIN pg_roles u ON u.oid = m.member
WHERE r.rolname = :'migrator_role'
  AND u.rolname = current_user
  AND m.set_option
  AND shobj_description(r.oid, 'pg_authid') = :'role_marker' \gset
\if :nettoyage_ok
\else
  SELECT 1/0 AS appartenance_restante;
\endif
