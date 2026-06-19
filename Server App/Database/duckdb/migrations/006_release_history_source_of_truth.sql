CREATE OR REPLACE VIEW reporting.v_release_history_table AS
SELECT
  COALESCE(activated_at, created_at) AS tested_at,
  'Release promoted: ' || release_id AS title,
  'release_promotion' AS event_type,
  COALESCE(status, '') AS status,
  NULL AS old_file,
  NULL AS new_file,
  '/release.html?release=' || release_id AS source_url,
  release_id AS test_label,
  COALESCE(notes, '') AS notes,
  NULL AS mod_id,
  'release.pack_releases' AS source,
  server_key,
  minecraft_version,
  loader_version
FROM release.pack_releases
WHERE COALESCE(activated_at, created_at) >= now() - INTERVAL 30 DAYS
ORDER BY tested_at DESC;

DROP TABLE IF EXISTS release.tested_updates_feed;
DROP VIEW IF EXISTS reporting.v_tested_updates_table;
