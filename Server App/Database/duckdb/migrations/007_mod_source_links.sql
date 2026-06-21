CREATE TABLE IF NOT EXISTS core.mod_source_links (
    link_id VARCHAR PRIMARY KEY,
    source_id VARCHAR NOT NULL,
    mod_key VARCHAR NOT NULL,
    display_name VARCHAR NOT NULL,
    provider VARCHAR NOT NULL,
    link_role VARCHAR NOT NULL,
    source_url VARCHAR NOT NULL,
    priority INTEGER NOT NULL DEFAULT 100,
    active BOOLEAN NOT NULL DEFAULT true,
    verified_at TIMESTAMP,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now(),
    minecraft_version VARCHAR DEFAULT '26.1.2',
    loader VARCHAR DEFAULT 'neoforge',
    loader_version VARCHAR,
    notes VARCHAR
);

INSERT OR REPLACE INTO core.mod_source_links(
    link_id,
    source_id,
    mod_key,
    display_name,
    provider,
    link_role,
    source_url,
    priority,
    active,
    verified_at,
    created_at,
    updated_at,
    minecraft_version,
    loader,
    loader_version,
    notes
)
SELECT
    'link_' || md5(
        COALESCE(source_id, '') || '|' ||
        COALESCE(minecraft_version, '26.1.2') || '|' ||
        COALESCE(provider, '') || '|' ||
        COALESCE(source_url, '')
    ) AS link_id,
    source_id,
    mod_key,
    display_name,
    provider,
    CASE
        WHEN lower(provider) IN ('modrinth', 'curseforge') THEN lower(provider)
        WHEN lower(provider) = 'neoforge' THEN 'official'
        WHEN lower(provider) IN ('web', 'adoptium') THEN 'official'
        ELSE 'primary'
    END AS link_role,
    source_url,
    priority,
    active,
    CASE
        WHEN source_url LIKE 'http://%' OR source_url LIKE 'https://%' THEN updated_at
        ELSE NULL
    END AS verified_at,
    COALESCE(created_at, now()),
    COALESCE(updated_at, now()),
    COALESCE(minecraft_version, '26.1.2'),
    COALESCE(loader, 'neoforge'),
    loader_version,
    'Backfilled from core.mod_sources by migration 007.'
FROM core.mod_sources
WHERE COALESCE(source_url, '') LIKE 'http://%'
   OR COALESCE(source_url, '') LIKE 'https://%';

CREATE INDEX IF NOT EXISTS idx_mod_source_links_source_id
    ON core.mod_source_links(source_id);
CREATE INDEX IF NOT EXISTS idx_mod_source_links_version_provider
    ON core.mod_source_links(minecraft_version, provider);
CREATE INDEX IF NOT EXISTS idx_mod_source_links_mod_key_version
    ON core.mod_source_links(mod_key, minecraft_version);

CREATE OR REPLACE VIEW reporting.v_mod_source_link_coverage AS
SELECT
    COALESCE(s.minecraft_version, l.minecraft_version) AS minecraft_version,
    COALESCE(s.mod_key, l.mod_key) AS mod_key,
    COALESCE(s.display_name, l.display_name) AS display_name,
    COUNT(DISTINCT l.source_url) AS source_url_count,
    COUNT(DISTINCT CASE WHEN l.provider = 'modrinth' THEN l.source_url END) AS modrinth_url_count,
    COUNT(DISTINCT CASE WHEN l.provider = 'curseforge' THEN l.source_url END) AS curseforge_url_count,
    COUNT(DISTINCT CASE WHEN l.link_role = 'official' THEN l.source_url END) AS official_url_count,
    string_agg(DISTINCT l.provider, ', ' ORDER BY l.provider) AS providers,
    string_agg(DISTINCT l.link_role || ':' || l.source_url, ' | ' ORDER BY l.link_role || ':' || l.source_url) AS source_links
FROM core.mod_sources s
LEFT JOIN core.mod_source_links l
  ON l.source_id = s.source_id
 AND COALESCE(l.minecraft_version, COALESCE(s.minecraft_version, '26.1.2')) = COALESCE(s.minecraft_version, '26.1.2')
WHERE COALESCE(s.source_url, '') LIKE 'http://%'
   OR COALESCE(s.source_url, '') LIKE 'https://%'
   OR l.source_url IS NOT NULL
GROUP BY 1, 2, 3;
