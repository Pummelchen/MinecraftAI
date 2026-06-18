-- Canonical version-keyed client inventory.

CREATE TABLE IF NOT EXISTS client.client_inventory_by_version (
  minecraft_version VARCHAR NOT NULL,
  loader_version VARCHAR,
  client_id VARCHAR NOT NULL,
  reported_at TIMESTAMP NOT NULL,
  section VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  size_bytes BIGINT NOT NULL,
  sha256 VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  PRIMARY KEY(minecraft_version, client_id, section, name)
);

INSERT OR REPLACE INTO client.client_inventory_by_version(
  minecraft_version, loader_version, client_id, reported_at, section,
  name, size_bytes, sha256, status
)
SELECT
  COALESCE(minecraft_version, '26.1.2') AS minecraft_version,
  loader_version,
  client_id,
  reported_at,
  section,
  name,
  size_bytes,
  sha256,
  status
FROM client.client_inventory;

CREATE INDEX IF NOT EXISTS idx_client_inventory_by_version_client_section
  ON client.client_inventory_by_version(minecraft_version, client_id, section);

CREATE OR REPLACE VIEW reporting.v_client_inventory_by_minecraft_version AS
SELECT
  i.minecraft_version,
  COALESCE(i.loader_version, v.loader_version) AS loader_version,
  i.client_id,
  i.section,
  COUNT(*) AS file_count,
  MAX(i.reported_at) AS last_reported_at
FROM client.client_inventory_by_version i
LEFT JOIN core.minecraft_server_versions v
  ON v.minecraft_version = i.minecraft_version
GROUP BY 1, 2, 3, 4
ORDER BY minecraft_version, client_id, section;
