-- Version-aware Minecraft server, mod, and client inventory state.

CREATE TABLE IF NOT EXISTS core.minecraft_server_versions (
  minecraft_version VARCHAR PRIMARY KEY,
  loader VARCHAR NOT NULL DEFAULT 'neoforge',
  loader_version VARCHAR NOT NULL,
  server_name VARCHAR NOT NULL,
  server_address VARCHAR NOT NULL,
  server_dir VARCHAR,
  status VARCHAR NOT NULL,
  is_live BOOLEAN NOT NULL DEFAULT false,
  sort_order INTEGER NOT NULL DEFAULT 100,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now(),
  notes VARCHAR
);

INSERT OR REPLACE INTO core.minecraft_server_versions(
  minecraft_version, loader, loader_version, server_name, server_address,
  server_dir, status, is_live, sort_order, created_at, updated_at, notes
)
VALUES
  (
    '26.1.2',
    'neoforge',
    '26.1.2.76',
    'Pummelchen Server 26.1.2',
    '91.99.176.243:25565',
    '/var/minecraft_26.1.2',
    'live',
    true,
    10,
    COALESCE((SELECT created_at FROM core.minecraft_server_versions WHERE minecraft_version = '26.1.2'), now()),
    now(),
    'Current live play target.'
  );

ALTER TABLE core.mods ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE core.mods ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
ALTER TABLE core.mods ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE core.mod_files ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE core.mod_files ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
ALTER TABLE core.mod_files ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE core.mod_server_files ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE core.mod_server_files ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
ALTER TABLE core.mod_server_files ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

CREATE TABLE IF NOT EXISTS core.mod_sources (
  source_id VARCHAR PRIMARY KEY,
  mod_key VARCHAR NOT NULL,
  display_name VARCHAR NOT NULL,
  installed_file VARCHAR,
  installed_version VARCHAR,
  provider VARCHAR NOT NULL,
  source_url VARCHAR NOT NULL,
  priority INTEGER NOT NULL DEFAULT 100,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS core.mod_update_scans (
  scan_id VARCHAR PRIMARY KEY,
  started_at TIMESTAMP NOT NULL,
  finished_at TIMESTAMP,
  status VARCHAR NOT NULL,
  urls_checked INTEGER NOT NULL DEFAULT 0,
  candidates_found INTEGER NOT NULL DEFAULT 0,
  unresolved INTEGER NOT NULL DEFAULT 0,
  notes VARCHAR
);

CREATE TABLE IF NOT EXISTS core.mod_update_scan_results (
  result_id VARCHAR PRIMARY KEY,
  scan_id VARCHAR NOT NULL,
  source_id VARCHAR NOT NULL,
  checked_at TIMESTAMP NOT NULL,
  provider VARCHAR NOT NULL,
  source_url VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  installed_file VARCHAR,
  installed_version VARCHAR,
  latest_version VARCHAR,
  latest_url VARCHAR,
  details VARCHAR
);

ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE core.mod_update_scans ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE core.mod_update_scans ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
ALTER TABLE core.mod_update_scans ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE core.mod_update_scan_results ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE core.mod_update_scan_results ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
ALTER TABLE core.mod_update_scan_results ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE client.client_reports ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
ALTER TABLE client.client_reports ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE client.client_latest_status ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
ALTER TABLE client.client_latest_status ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE client.client_inventory ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
ALTER TABLE client.client_inventory ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE client.client_defaults_reports ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
ALTER TABLE client.client_defaults_reports ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

ALTER TABLE client.client_defaults_events ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
ALTER TABLE client.client_defaults_events ADD COLUMN IF NOT EXISTS loader_version VARCHAR;

CREATE INDEX IF NOT EXISTS idx_core_versions_status_order
  ON core.minecraft_server_versions(status, sort_order);
CREATE INDEX IF NOT EXISTS idx_core_mod_sources_version_active
  ON core.mod_sources(minecraft_version, active, priority);
CREATE INDEX IF NOT EXISTS idx_core_mod_scan_results_version_time
  ON core.mod_update_scan_results(minecraft_version, checked_at);
CREATE INDEX IF NOT EXISTS idx_client_inventory_version_client_section
  ON client.client_inventory(minecraft_version, client_id, section);

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
  notes
FROM core.minecraft_server_versions
ORDER BY sort_order, minecraft_version;

CREATE OR REPLACE VIEW reporting.v_mods_by_minecraft_version AS
SELECT
  COALESCE(m.minecraft_version, '26.1.2') AS minecraft_version,
  COALESCE(m.loader, 'neoforge') AS loader,
  COALESCE(m.loader_version, v.loader_version) AS loader_version,
  COUNT(*) AS mod_count,
  SUM(CASE WHEN m.active_status = 'active' THEN 1 ELSE 0 END) AS active_mod_count,
  MAX(m.updated_at) AS last_updated_at
FROM core.mods m
LEFT JOIN core.minecraft_server_versions v
  ON v.minecraft_version = COALESCE(m.minecraft_version, '26.1.2')
GROUP BY 1, 2, 3
ORDER BY 1;

CREATE OR REPLACE VIEW reporting.v_client_inventory_by_minecraft_version AS
SELECT
  COALESCE(i.minecraft_version, '26.1.2') AS minecraft_version,
  COALESCE(i.loader_version, v.loader_version) AS loader_version,
  i.client_id,
  i.section,
  COUNT(*) AS file_count,
  MAX(i.reported_at) AS last_reported_at
FROM client.client_inventory i
LEFT JOIN core.minecraft_server_versions v
  ON v.minecraft_version = COALESCE(i.minecraft_version, '26.1.2')
GROUP BY 1, 2, 3, 4
ORDER BY minecraft_version, client_id, section;
