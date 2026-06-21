CREATE TABLE IF NOT EXISTS core.mod_source_discovery_results (
    discovery_id VARCHAR PRIMARY KEY,
    source_id VARCHAR NOT NULL,
    mod_key VARCHAR NOT NULL,
    display_name VARCHAR NOT NULL,
    missing_provider VARCHAR NOT NULL,
    search_method VARCHAR NOT NULL,
    search_url VARCHAR NOT NULL,
    found_url VARCHAR,
    status VARCHAR NOT NULL,
    details VARCHAR,
    checked_at TIMESTAMP NOT NULL DEFAULT now(),
    minecraft_version VARCHAR DEFAULT '26.1.2',
    loader VARCHAR DEFAULT 'neoforge',
    loader_version VARCHAR
);

CREATE INDEX IF NOT EXISTS idx_mod_source_discovery_source_provider
    ON core.mod_source_discovery_results(source_id, missing_provider);
CREATE INDEX IF NOT EXISTS idx_mod_source_discovery_version_provider
    ON core.mod_source_discovery_results(minecraft_version, missing_provider);
