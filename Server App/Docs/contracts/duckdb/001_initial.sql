-- Pummelchen Swift/DuckDB baseline schema.
-- Phase 0 defines the target contracts only. Phase 1 imports and validates parity
-- from the current SQLite database and project files.

CREATE SCHEMA IF NOT EXISTS ops;
CREATE SCHEMA IF NOT EXISTS release;
CREATE SCHEMA IF NOT EXISTS client;
CREATE SCHEMA IF NOT EXISTS moddb;
CREATE SCHEMA IF NOT EXISTS world;
CREATE SCHEMA IF NOT EXISTS control;

CREATE TABLE IF NOT EXISTS ops.schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMP NOT NULL DEFAULT now(),
    checksum TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS release.pack_releases (
    release_id TEXT PRIMARY KEY,
    created_at TIMESTAMP NOT NULL,
    activated_at TIMESTAMP,
    server_key TEXT NOT NULL,
    minecraft_version TEXT,
    loader_version TEXT,
    server_dir TEXT NOT NULL,
    release_dir TEXT NOT NULL,
    status TEXT NOT NULL,
    active BOOLEAN NOT NULL DEFAULT false,
    previous_release_id TEXT,
    git_commit TEXT,
    server_manifest_sha256 TEXT,
    client_manifest_sha256 TEXT,
    db_snapshot_sha256 TEXT,
    client_zip_sha256 TEXT,
    mrpack_sha256 TEXT,
    dmg_sha256 TEXT,
    changelog_path TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS release.release_artifacts (
    artifact_id UBIGINT PRIMARY KEY,
    release_id TEXT NOT NULL,
    artifact_role TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    source_path TEXT,
    size_bytes UBIGINT,
    sha256 TEXT,
    created_at TIMESTAMP NOT NULL,
    UNIQUE (release_id, artifact_role, relative_path)
);

CREATE TABLE IF NOT EXISTS release.release_events (
    event_id UBIGINT PRIMARY KEY,
    release_id TEXT,
    event_at TIMESTAMP NOT NULL,
    event_type TEXT NOT NULL,
    status TEXT NOT NULL,
    actor TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS release.release_health_results (
    result_id TEXT PRIMARY KEY,
    release_id TEXT NOT NULL,
    checked_at TIMESTAMP NOT NULL,
    status TEXT NOT NULL,
    details TEXT
);

CREATE TABLE IF NOT EXISTS release.tested_updates_feed (
    update_id TEXT PRIMARY KEY,
    release_id TEXT,
    tested_at TIMESTAMP,
    title TEXT,
    status TEXT,
    details TEXT
);

CREATE TABLE IF NOT EXISTS client.client_reports (
    client_id TEXT NOT NULL,
    reported_at TIMESTAMP NOT NULL,
    installed_release_id TEXT,
    target_release_id TEXT,
    status TEXT NOT NULL,
    manifest_entries INTEGER,
    changed_files INTEGER,
    last_error TEXT,
    message TEXT,
    os_summary TEXT,
    arch TEXT
);

CREATE TABLE IF NOT EXISTS client.client_latest_status (
    client_id TEXT PRIMARY KEY,
    first_seen_at TIMESTAMP NOT NULL,
    last_seen_at TIMESTAMP NOT NULL,
    installed_release_id TEXT,
    target_release_id TEXT,
    status TEXT NOT NULL,
    manifest_entries INTEGER,
    changed_files INTEGER,
    last_error TEXT,
    last_status_message TEXT,
    os_summary TEXT,
    arch TEXT
);

CREATE TABLE IF NOT EXISTS client.client_inventory (
    client_id TEXT NOT NULL,
    reported_at TIMESTAMP NOT NULL,
    section TEXT NOT NULL,
    name TEXT NOT NULL,
    size_bytes UBIGINT NOT NULL,
    sha256 TEXT NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (client_id, section, name)
);

CREATE TABLE IF NOT EXISTS client.client_diagnostics (
    diagnostic_id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    reported_at TIMESTAMP NOT NULL,
    level TEXT NOT NULL,
    summary TEXT NOT NULL,
    details TEXT
);

CREATE TABLE IF NOT EXISTS client.client_defaults_reports (
    report_id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    reported_at TIMESTAMP NOT NULL,
    defaults_ok BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS client.client_defaults_events (
    event_id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    reported_at TIMESTAMP NOT NULL,
    key TEXT NOT NULL,
    status TEXT NOT NULL,
    desired_value TEXT NOT NULL,
    observed_value TEXT
);

CREATE TABLE IF NOT EXISTS control.control_events (
    event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL,
    target_client_id TEXT,
    release_id TEXT,
    priority TEXT NOT NULL,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    payload_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS control.control_acks (
    client_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    received_at TIMESTAMP NOT NULL,
    PRIMARY KEY (client_id, event_id)
);

CREATE TABLE IF NOT EXISTS moddb.mods (
    mod_id UBIGINT PRIMARY KEY,
    canonical_key TEXT NOT NULL,
    name TEXT NOT NULL,
    side TEXT,
    primary_url TEXT,
    active_status TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS moddb.mod_files (
    mod_file_id UBIGINT PRIMARY KEY,
    mod_id UBIGINT NOT NULL,
    role TEXT NOT NULL,
    file_name TEXT NOT NULL,
    file_sha256 TEXT,
    file_size_bytes UBIGINT,
    installed_on_server BOOLEAN NOT NULL DEFAULT false,
    included_in_client BOOLEAN NOT NULL DEFAULT false,
    status TEXT
);

CREATE TABLE IF NOT EXISTS moddb.tested_updates (
    update_id TEXT PRIMARY KEY,
    tested_at TIMESTAMP,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    event_type TEXT NOT NULL,
    status TEXT NOT NULL,
    old_file TEXT,
    new_file TEXT,
    source_url TEXT,
    test_label TEXT,
    notes TEXT,
    mod_id UBIGINT
);

CREATE TABLE IF NOT EXISTS world.reset_jobs (
    job_id TEXT PRIMARY KEY,
    requested_at TIMESTAMP NOT NULL,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    status TEXT NOT NULL,
    seed TEXT,
    radius_blocks INTEGER NOT NULL DEFAULT 1000,
    old_world_path TEXT,
    backup_path TEXT,
    result_json JSON,
    error TEXT
);

CREATE TABLE IF NOT EXISTS ops.jobs (
    job_id TEXT PRIMARY KEY,
    job_type TEXT NOT NULL,
    requested_at TIMESTAMP NOT NULL,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    status TEXT NOT NULL,
    requested_by TEXT,
    input_json JSON,
    result_json JSON,
    error TEXT
);

CREATE TABLE IF NOT EXISTS ops.audit_log (
    audit_id UBIGINT PRIMARY KEY,
    event_at TIMESTAMP NOT NULL,
    actor TEXT,
    action TEXT NOT NULL,
    target_type TEXT,
    target_id TEXT,
    detail_json JSON
);

CREATE VIEW IF NOT EXISTS release.active_release AS
SELECT *
FROM release.pack_releases
WHERE active = true
ORDER BY activated_at DESC
LIMIT 1;

CREATE VIEW IF NOT EXISTS client.latest_problem_clients AS
SELECT *
FROM client.client_latest_status
WHERE status NOT IN ('synced')
ORDER BY last_seen_at DESC;
