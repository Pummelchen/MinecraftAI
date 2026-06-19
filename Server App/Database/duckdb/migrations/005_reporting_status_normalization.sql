-- Normalize accepted mod states in reporting views.
-- The production mod table uses `ok` for accepted active mods, not only `active`.

CREATE OR REPLACE VIEW reporting.v_mods_by_minecraft_version AS
SELECT
  COALESCE(m.minecraft_version, '26.1.2') AS minecraft_version,
  COALESCE(m.loader, 'neoforge') AS loader,
  COALESCE(m.loader_version, v.loader_version) AS loader_version,
  COUNT(*) AS mod_count,
  SUM(
    CASE
      WHEN lower(COALESCE(m.active_status, '')) IN ('active', 'ok') THEN 1
      ELSE 0
    END
  ) AS active_mod_count,
  MAX(m.updated_at) AS last_updated_at
FROM core.mods m
LEFT JOIN core.minecraft_server_versions v
  ON v.minecraft_version = COALESCE(m.minecraft_version, '26.1.2')
GROUP BY 1, 2, 3
ORDER BY 1;
