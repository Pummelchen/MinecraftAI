-- Rebuild normalized core tables from raw SQLite imports.

DELETE FROM core.pack_releases;
INSERT INTO core.pack_releases
SELECT
    release_id,
    try_cast(created_at AS TIMESTAMP),
    try_cast(activated_at AS TIMESTAMP),
    server_key,
    minecraft_version,
    loader_version,
    server_dir,
    release_dir,
    status,
    active = 1,
    previous_release_id,
    git_commit,
    server_manifest_sha256,
    client_manifest_sha256,
    db_snapshot_sha256,
    client_zip_sha256,
    mrpack_sha256,
    changelog_path,
    notes
FROM raw.pack_releases;

DELETE FROM core.release_artifacts;
INSERT INTO core.release_artifacts
SELECT
    id,
    release_id,
    artifact_role,
    relative_path,
    source_path,
    size_bytes,
    sha256,
    try_cast(created_at AS TIMESTAMP)
FROM raw.release_artifacts;

DELETE FROM core.release_events;
INSERT INTO core.release_events
SELECT
    id,
    release_id,
    try_cast(event_at AS TIMESTAMP),
    event_type,
    status,
    actor,
    notes
FROM raw.release_events;

DELETE FROM core.mods;
INSERT INTO core.mods
SELECT
    id,
    canonical_key,
    name,
    category,
    active_status,
    server_status,
    client_package,
    primary_url,
    try_cast(updated_at AS TIMESTAMP)
FROM raw.mods;

DELETE FROM core.mod_files;
INSERT INTO core.mod_files
SELECT
    id,
    mod_id,
    role,
    file_name,
    path_hint,
    installed_on_server = 1,
    included_in_client = 1,
    status
FROM raw.mod_files;

DELETE FROM core.mod_server_files;
INSERT INTO core.mod_server_files
SELECT
    id,
    mod_id,
    file_name,
    role,
    source_url,
    compatibility_status,
    installed_on_server = 1,
    included_in_client = 1,
    selected = 1,
    file_sha256,
    file_size_bytes,
    try_cast(last_synced AS TIMESTAMP),
    notes
FROM raw.mod_server_files;

DELETE FROM core.update_events;
INSERT INTO core.update_events
SELECT
    id,
    update_run_id,
    mod_id,
    event_type,
    status,
    old_file_name,
    new_file_name,
    source_kind,
    source_url,
    try_cast(tested_at AS TIMESTAMP),
    test_label,
    visible_on_site = 1,
    notes
FROM raw.update_events;

DELETE FROM core.mod_acceptance_blocks;
INSERT INTO core.mod_acceptance_blocks
SELECT
    id,
    acceptance_release_id,
    level,
    ordinal,
    block_key,
    status,
    target_file_names,
    included_file_names,
    run_label,
    try_cast(created_at AS TIMESTAMP),
    notes
FROM raw.mod_acceptance_blocks;

DELETE FROM core.mod_acceptance_releases;
INSERT INTO core.mod_acceptance_releases
SELECT
    id,
    release_key,
    try_cast(completed_at AS TIMESTAMP),
    status,
    bundle_size,
    active_file_count,
    level_count,
    notes
FROM raw.mod_acceptance_releases;

DELETE FROM core.test_runs;
INSERT INTO core.test_runs
SELECT
    id,
    mod_id,
    try_cast(tested_at AS TIMESTAMP),
    test_label,
    status,
    notes
FROM raw.test_runs;

DELETE FROM core.headless_client_runs;
INSERT INTO core.headless_client_runs
SELECT
    id,
    release_id,
    try_cast(started_at AS TIMESTAMP),
    status,
    renderer_summary,
    duration_seconds,
    crash_report_count,
    fatal_log_count,
    notes
FROM raw.headless_client_runs;

DELETE FROM core.client_update_status;
INSERT INTO core.client_update_status
SELECT
    client_id,
    try_cast(first_seen_at AS TIMESTAMP),
    try_cast(last_seen_at AS TIMESTAMP),
    installed_release_id,
    target_release_id,
    status,
    manifest_entries,
    changed_files,
    last_error,
    last_status_message,
    os_summary,
    arch
FROM raw.client_update_status;
