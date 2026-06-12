-- Phase 1 DuckDB foundation.
-- Current SQLite/Python remains the production writer during this phase.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS reporting;
CREATE SCHEMA IF NOT EXISTS archive;

CREATE TABLE IF NOT EXISTS core.schema_migrations (
    version INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL,
    applied_at TIMESTAMP NOT NULL,
    checksum VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS core.pack_releases (
    release_id VARCHAR PRIMARY KEY,
    created_at TIMESTAMP,
    activated_at TIMESTAMP,
    server_key VARCHAR NOT NULL,
    minecraft_version VARCHAR,
    loader_version VARCHAR,
    server_dir VARCHAR,
    release_dir VARCHAR,
    status VARCHAR NOT NULL,
    active BOOLEAN NOT NULL DEFAULT false,
    previous_release_id VARCHAR,
    git_commit VARCHAR,
    server_manifest_sha256 VARCHAR,
    client_manifest_sha256 VARCHAR,
    db_snapshot_sha256 VARCHAR,
    client_zip_sha256 VARCHAR,
    mrpack_sha256 VARCHAR,
    changelog_path VARCHAR,
    notes VARCHAR
);

CREATE TABLE IF NOT EXISTS core.release_artifacts (
    id BIGINT PRIMARY KEY,
    release_id VARCHAR NOT NULL,
    artifact_role VARCHAR NOT NULL,
    relative_path VARCHAR NOT NULL,
    source_path VARCHAR,
    size_bytes BIGINT,
    sha256 VARCHAR,
    created_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS core.release_events (
    id BIGINT PRIMARY KEY,
    release_id VARCHAR,
    event_at TIMESTAMP,
    event_type VARCHAR NOT NULL,
    status VARCHAR NOT NULL,
    actor VARCHAR,
    notes VARCHAR
);

CREATE TABLE IF NOT EXISTS core.mods (
    id BIGINT PRIMARY KEY,
    canonical_key VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    category VARCHAR,
    active_status VARCHAR NOT NULL,
    server_status VARCHAR,
    client_package VARCHAR,
    primary_url VARCHAR,
    updated_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS core.mod_files (
    id BIGINT PRIMARY KEY,
    mod_id BIGINT NOT NULL,
    role VARCHAR NOT NULL,
    file_name VARCHAR NOT NULL,
    path_hint VARCHAR,
    installed_on_server BOOLEAN NOT NULL DEFAULT false,
    included_in_client BOOLEAN NOT NULL DEFAULT false,
    status VARCHAR
);

CREATE TABLE IF NOT EXISTS core.mod_server_files (
    id BIGINT PRIMARY KEY,
    mod_id BIGINT NOT NULL,
    file_name VARCHAR NOT NULL,
    role VARCHAR NOT NULL,
    source_url VARCHAR,
    compatibility_status VARCHAR NOT NULL,
    installed_on_server BOOLEAN NOT NULL DEFAULT false,
    included_in_client BOOLEAN NOT NULL DEFAULT false,
    selected BOOLEAN NOT NULL DEFAULT true,
    file_sha256 VARCHAR,
    file_size_bytes BIGINT,
    last_synced TIMESTAMP,
    notes VARCHAR
);

CREATE TABLE IF NOT EXISTS core.update_events (
    id BIGINT PRIMARY KEY,
    update_run_id BIGINT NOT NULL,
    mod_id BIGINT,
    event_type VARCHAR NOT NULL,
    status VARCHAR NOT NULL,
    old_file_name VARCHAR,
    new_file_name VARCHAR,
    source_kind VARCHAR,
    source_url VARCHAR,
    tested_at TIMESTAMP,
    test_label VARCHAR,
    visible_on_site BOOLEAN NOT NULL DEFAULT false,
    notes VARCHAR
);

CREATE TABLE IF NOT EXISTS core.mod_acceptance_blocks (
    id BIGINT PRIMARY KEY,
    block_key VARCHAR NOT NULL,
    status VARCHAR NOT NULL,
    target_file_names VARCHAR NOT NULL,
    run_label VARCHAR,
    created_at TIMESTAMP,
    notes VARCHAR
);

CREATE TABLE IF NOT EXISTS core.client_update_status (
    client_id VARCHAR PRIMARY KEY,
    first_seen_at TIMESTAMP,
    last_seen_at TIMESTAMP,
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

CREATE TABLE IF NOT EXISTS core.world_reset_history (
    job_id VARCHAR PRIMARY KEY,
    requested_at TIMESTAMP,
    completed_at TIMESTAMP,
    status VARCHAR NOT NULL,
    seed VARCHAR,
    radius_blocks INTEGER,
    old_world_path VARCHAR,
    backup_path VARCHAR,
    notes VARCHAR
);

CREATE TABLE IF NOT EXISTS audit.parquet_exports (
    export_id VARCHAR PRIMARY KEY,
    exported_at TIMESTAMP NOT NULL,
    source_name VARCHAR NOT NULL,
    output_path VARCHAR NOT NULL,
    row_count BIGINT,
    sha256 VARCHAR
);

CREATE OR REPLACE VIEW reporting.v_tested_updates_table AS
SELECT
    COALESCE(u.tested_at, a.created_at) AS tested_at,
    COALESCE(m.name, u.new_file_name, a.block_key) AS title,
    COALESCE(u.event_type, 'acceptance_pyramid_L0') AS event_type,
    COALESCE(u.status, a.status) AS status,
    u.old_file_name AS old_file,
    COALESCE(u.new_file_name, a.target_file_names) AS new_file,
    u.source_url,
    COALESCE(u.test_label, a.run_label) AS test_label,
    COALESCE(u.notes, a.notes) AS notes,
    m.id AS mod_id
FROM core.update_events u
LEFT JOIN core.mods m ON m.id = u.mod_id
FULL OUTER JOIN core.mod_acceptance_blocks a ON false
WHERE COALESCE(u.visible_on_site, true) = true OR a.id IS NOT NULL;

CREATE OR REPLACE VIEW reporting.v_failed_mods_table AS
SELECT
    m.updated_at AS failed_at,
    m.name AS title,
    m.primary_url AS source_url,
    COALESCE(msf.file_name, mf.file_name) AS file_name,
    m.active_status AS failure_reason,
    COALESCE(msf.notes, mf.status, m.server_status, 'No extra detail recorded') AS details
FROM core.mods m
LEFT JOIN core.mod_server_files msf ON msf.mod_id = m.id
LEFT JOIN core.mod_files mf ON mf.mod_id = m.id
WHERE lower(m.active_status) = 'failed';

CREATE OR REPLACE VIEW reporting.v_release_health_latest AS
SELECT
    pr.release_id,
    pr.activated_at,
    pr.status,
    pr.active,
    pr.client_zip_sha256,
    pr.mrpack_sha256,
    COUNT(ra.id) AS artifact_count,
    SUM(COALESCE(ra.size_bytes, 0)) AS artifact_bytes
FROM core.pack_releases pr
LEFT JOIN core.release_artifacts ra ON ra.release_id = pr.release_id
WHERE pr.active = true
GROUP BY
    pr.release_id,
    pr.activated_at,
    pr.status,
    pr.active,
    pr.client_zip_sha256,
    pr.mrpack_sha256
ORDER BY pr.activated_at DESC
LIMIT 1;

CREATE OR REPLACE VIEW reporting.v_client_sync_status AS
SELECT
    client_id,
    last_seen_at,
    installed_release_id,
    target_release_id,
    status,
    manifest_entries,
    changed_files,
    last_error,
    last_status_message,
    os_summary,
    arch
FROM core.client_update_status
ORDER BY last_seen_at DESC;

CREATE OR REPLACE VIEW reporting.v_custom_datapack_status AS
SELECT
    pr.release_id,
    ra.relative_path,
    ra.size_bytes,
    ra.sha256,
    ra.created_at,
    CASE WHEN ra.sha256 IS NOT NULL AND ra.sha256 <> '' THEN 'present' ELSE 'missing_checksum' END AS status
FROM core.release_artifacts ra
JOIN core.pack_releases pr ON pr.release_id = ra.release_id
WHERE ra.relative_path LIKE '%server-datapacks/pummelchen-%'
ORDER BY pr.created_at DESC, ra.relative_path;

CREATE OR REPLACE VIEW reporting.v_world_reset_history AS
SELECT
    requested_at,
    completed_at,
    status,
    seed,
    radius_blocks,
    old_world_path,
    backup_path,
    notes
FROM core.world_reset_history
ORDER BY COALESCE(completed_at, requested_at) DESC;

CREATE OR REPLACE VIEW reporting.v_duckdb_health AS
SELECT
    (SELECT COUNT(*) FROM core.schema_migrations) AS migration_count,
    (SELECT max(version) FROM core.schema_migrations) AS schema_version,
    (SELECT COUNT(*) FROM core.pack_releases) AS release_count,
    (SELECT COUNT(*) FROM core.mods) AS mod_count,
    (SELECT COUNT(*) FROM core.client_update_status) AS client_status_count;
