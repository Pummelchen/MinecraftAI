-- Canonical operational schemas and DuckDB ART indexes for frequent lookups.

CREATE SCHEMA IF NOT EXISTS client;
CREATE SCHEMA IF NOT EXISTS control;
CREATE SCHEMA IF NOT EXISTS release;
CREATE SCHEMA IF NOT EXISTS world;

CREATE TABLE IF NOT EXISTS client.client_reports (
  client_id VARCHAR NOT NULL,
  reported_at TIMESTAMP NOT NULL,
  installed_release_id VARCHAR,
  target_release_id VARCHAR,
  status VARCHAR NOT NULL,
  manifest_entries INTEGER,
  changed_files INTEGER,
  last_error VARCHAR,
  message VARCHAR,
  os_summary VARCHAR,
  arch VARCHAR
);

CREATE TABLE IF NOT EXISTS client.client_latest_status (
  client_id VARCHAR PRIMARY KEY,
  first_seen_at TIMESTAMP NOT NULL,
  last_seen_at TIMESTAMP NOT NULL,
  installed_release_id VARCHAR,
  target_release_id VARCHAR,
  status VARCHAR NOT NULL,
  manifest_entries INTEGER,
  changed_files INTEGER,
  last_error VARCHAR,
  last_status_message VARCHAR,
  os_summary VARCHAR,
  arch VARCHAR
);

CREATE TABLE IF NOT EXISTS client.client_inventory (
  client_id VARCHAR NOT NULL,
  reported_at TIMESTAMP NOT NULL,
  section VARCHAR NOT NULL,
  name VARCHAR NOT NULL,
  size_bytes BIGINT NOT NULL,
  sha256 VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  PRIMARY KEY(client_id, section, name)
);

CREATE TABLE IF NOT EXISTS client.client_diagnostics (
  diagnostic_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  reported_at TIMESTAMP NOT NULL,
  level VARCHAR NOT NULL,
  summary VARCHAR NOT NULL,
  details VARCHAR,
  client_ip VARCHAR,
  log_files VARCHAR,
  log_snippet VARCHAR
);

ALTER TABLE client.client_diagnostics ADD COLUMN IF NOT EXISTS client_ip VARCHAR;
ALTER TABLE client.client_diagnostics ADD COLUMN IF NOT EXISTS log_files VARCHAR;
ALTER TABLE client.client_diagnostics ADD COLUMN IF NOT EXISTS log_snippet VARCHAR;

CREATE TABLE IF NOT EXISTS client.client_defaults_reports (
  report_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  reported_at TIMESTAMP NOT NULL,
  defaults_ok BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS client.client_defaults_events (
  event_id VARCHAR PRIMARY KEY,
  client_id VARCHAR NOT NULL,
  reported_at TIMESTAMP NOT NULL,
  key VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  desired_value VARCHAR NOT NULL,
  observed_value VARCHAR
);

CREATE TABLE IF NOT EXISTS control.control_events (
  event_id VARCHAR PRIMARY KEY,
  event_type VARCHAR NOT NULL,
  created_at TIMESTAMP NOT NULL,
  target_client_id VARCHAR,
  release_id VARCHAR,
  priority VARCHAR NOT NULL,
  title VARCHAR NOT NULL,
  message VARCHAR NOT NULL,
  payload_json VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS control.control_acks (
  client_id VARCHAR NOT NULL,
  event_id VARCHAR NOT NULL,
  received_at TIMESTAMP NOT NULL,
  PRIMARY KEY(client_id, event_id)
);

CREATE TABLE IF NOT EXISTS release.pack_releases (
  release_id VARCHAR PRIMARY KEY,
  created_at TIMESTAMP NOT NULL,
  activated_at TIMESTAMP,
  server_key VARCHAR NOT NULL,
  minecraft_version VARCHAR,
  loader_version VARCHAR,
  server_dir VARCHAR NOT NULL,
  release_dir VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  active BOOLEAN NOT NULL DEFAULT false,
  previous_release_id VARCHAR,
  git_commit VARCHAR,
  server_manifest_sha256 VARCHAR,
  client_manifest_sha256 VARCHAR,
  db_snapshot_sha256 VARCHAR,
  client_zip_sha256 VARCHAR,
  mrpack_sha256 VARCHAR,
  dmg_sha256 VARCHAR,
  changelog_path VARCHAR,
  notes VARCHAR
);

CREATE TABLE IF NOT EXISTS release.release_events (
  event_id VARCHAR PRIMARY KEY,
  release_id VARCHAR,
  event_at TIMESTAMP NOT NULL,
  event_type VARCHAR NOT NULL,
  status VARCHAR NOT NULL,
  actor VARCHAR,
  notes VARCHAR
);

CREATE TABLE IF NOT EXISTS release.release_health_results (
  result_id VARCHAR PRIMARY KEY,
  release_id VARCHAR NOT NULL,
  checked_at TIMESTAMP NOT NULL,
  status VARCHAR NOT NULL,
  details VARCHAR
);

CREATE TABLE IF NOT EXISTS world.reset_jobs (
  job_id VARCHAR PRIMARY KEY,
  requested_at TIMESTAMP NOT NULL,
  started_at TIMESTAMP,
  completed_at TIMESTAMP,
  status VARCHAR NOT NULL,
  seed VARCHAR,
  radius_blocks INTEGER NOT NULL DEFAULT 1000,
  old_world_path VARCHAR,
  backup_path VARCHAR,
  result_json JSON,
  error VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_core_pack_releases_active_server_time
  ON core.pack_releases(server_key, active, activated_at);
CREATE INDEX IF NOT EXISTS idx_core_update_events_site_status_time
  ON core.update_events(visible_on_site, status, tested_at);
CREATE INDEX IF NOT EXISTS idx_core_mods_status_updated
  ON core.mods(active_status, updated_at);
CREATE INDEX IF NOT EXISTS idx_core_mod_server_files_mod_selected
  ON core.mod_server_files(mod_id, selected);
CREATE INDEX IF NOT EXISTS idx_core_mod_files_mod_role
  ON core.mod_files(mod_id, role);
CREATE INDEX IF NOT EXISTS idx_core_test_runs_mod_time
  ON core.test_runs(mod_id, tested_at);
CREATE INDEX IF NOT EXISTS idx_core_acceptance_blocks_status_time
  ON core.mod_acceptance_blocks(status, created_at);
CREATE INDEX IF NOT EXISTS idx_core_headless_status_time
  ON core.headless_client_runs(status, started_at);

CREATE INDEX IF NOT EXISTS idx_client_latest_status_status_seen
  ON client.client_latest_status(status, last_seen_at);
CREATE INDEX IF NOT EXISTS idx_client_reports_client_time
  ON client.client_reports(client_id, reported_at);
CREATE INDEX IF NOT EXISTS idx_client_inventory_client_section
  ON client.client_inventory(client_id, section);
CREATE INDEX IF NOT EXISTS idx_client_diagnostics_client_time
  ON client.client_diagnostics(client_id, reported_at);
CREATE INDEX IF NOT EXISTS idx_client_defaults_events_client_time
  ON client.client_defaults_events(client_id, reported_at);

CREATE INDEX IF NOT EXISTS idx_control_events_target_time
  ON control.control_events(target_client_id, created_at);
CREATE INDEX IF NOT EXISTS idx_control_events_release_time
  ON control.control_events(release_id, created_at);
CREATE INDEX IF NOT EXISTS idx_control_acks_event
  ON control.control_acks(event_id);

CREATE INDEX IF NOT EXISTS idx_release_pack_active_server_time
  ON release.pack_releases(server_key, active, activated_at);
CREATE INDEX IF NOT EXISTS idx_release_events_release_time
  ON release.release_events(release_id, event_at);
CREATE INDEX IF NOT EXISTS idx_release_health_release_time
  ON release.release_health_results(release_id, checked_at);
CREATE INDEX IF NOT EXISTS idx_world_reset_status_time
  ON world.reset_jobs(status, requested_at);
