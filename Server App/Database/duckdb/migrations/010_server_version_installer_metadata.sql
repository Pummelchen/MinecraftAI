-- Publish client-installable NeoForge requirements from DuckDB.
-- The macOS client uses these fields to learn future supported Minecraft
-- versions without requiring a DMG rebuild for every new version line.

ALTER TABLE core.minecraft_server_versions ADD COLUMN IF NOT EXISTS installer_name VARCHAR;
ALTER TABLE core.minecraft_server_versions ADD COLUMN IF NOT EXISTS installer_sha256 VARCHAR;
ALTER TABLE core.minecraft_server_versions ADD COLUMN IF NOT EXISTS installer_url VARCHAR;

UPDATE core.minecraft_server_versions
SET
  installer_name = 'neoforge-26.1.2.76-installer.jar',
  installer_sha256 = 'f67bf87ddf8f3095ddbae4c78dbbbf5615e08b6982f4e84159eab951235974ec',
  installer_url = 'https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.2.76/neoforge-26.1.2.76-installer.jar',
  updated_at = now()
WHERE minecraft_version = '26.1.2'
  AND loader_version = '26.1.2.76';

CREATE OR REPLACE VIEW reporting.v_minecraft_server_versions AS
SELECT
  minecraft_version,
  loader,
  loader_version,
  server_name,
  server_address,
  server_dir,
  status,
  is_live,
  sort_order,
  updated_at,
  notes,
  installer_name,
  installer_sha256,
  installer_url
FROM core.minecraft_server_versions
ORDER BY sort_order, minecraft_version;
