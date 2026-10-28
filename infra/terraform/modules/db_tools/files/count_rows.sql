-- Nombre de lignes de chaque table du schéma public (une ligne « table nombre »), utilisé par
-- le test de restauration pour comparer la copie restaurée et la base source.
SELECT table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text::bigint AS lignes
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
