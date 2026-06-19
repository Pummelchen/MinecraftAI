# Pummelchen Production Contracts

This document freezes the production behavior for the Swift/DuckDB production system.

## Project Location

The Swift production project lives in the repository folders `Server App`, `Client App`, `Server App/Database`, `Server App/nginx`, and `Live Backup`.

Reason:

- `Server App` owns the Debian service, release orchestration, safe world reset, DuckDB writes, and nginx-facing API data.
- `Client App` owns the macOS app, background sync, local status database, and player-facing sync UI.
- `Server App/MCPummelchenModShared` owns the shared contracts used by both sides.

The client identity/token model is frozen in `docs/contracts/CLIENT_IDENTITY.md`.

## Updater Flow

1. Client resolves `/downloads/current-release.json`.
2. Client reads `release_id` and `manifest_url`.
3. Client downloads `/downloads/releases/<release-id>/client-sync-manifest.tsv`.
4. Client compares each listed file by path, size, and SHA256.
5. Client downloads only missing or changed files.
6. Downloads must use temporary files, verify SHA256, then atomically replace the final path.
7. If no files need download, the client must still show or print a useful all-synced summary.

## Manual Repair

Manual repair is handled by the Swift client app and its bundled sync helper. The website must not publish shell-based repair commands.

## Runtime And Build Tool Boundary

The production runtime boundary is Swift + embedded DuckDB + nginx. Live server duties, client sync control, release metadata, safe world reset, mod inventory, failed-mod status, client reports, and website API data must be owned by the Swift server/client apps and DuckDB.

Shell scripts and small Python snippets are allowed only in developer/build/test tooling, such as local DMG packaging wrappers, temporary HTTP servers in tests, or command hooks explicitly passed by an operator. They must not become always-on VPS services, cron jobs, website data generators, or client runtime repair logic.

## Client No-Download Summary

When nothing needs download, the manual updater and future Swift CLI must report:

- server release ID
- installed/client release ID
- verified file count
- changed file count of `0`
- clear all-synced/no-downloads-required message

## DMG Contents

Current DMG contents must remain functionally available:

- installer entrypoint
- Swift client app
- bundled Swift sync helper
- client manifest
- resource packs
- shader packs
- default configs
- Pummelchen server entry setup

The DMG installs `MCPummelchenModClient.app` and keeps CLI repair functionality inside the app bundle.

The app bundle `Info.plist` must include `PummelchenReleaseID` set to the release being built. The sync engine compares this value to the server release. If the server advertises matching DMG metadata and the installed app is older or missing the release marker, the client downloads the DMG, verifies SHA256, mounts it read-only, validates the app bundle/signature/helper/embedded DuckDB dylib, stages the replacement, exits, installs the new app bundle, and opens the app again.

Private DMGs for the current closed player group include the `client-api-token` bootstrap resource when `PUMMELCHEN_CLIENT_API_TOKEN` is supplied to the DMG builder. That token is a private distribution credential: it must never be committed to Git, printed in logs, uploaded in diagnostics, or exposed in public website/release metadata. The long-term identity model remains per-client `client_id` plus local secret storage as defined in `CLIENT_IDENTITY.md`.

## Client Defaults

Client defaults are idempotent. Repeated syncs must not duplicate config keys or reset unrelated player preferences.

Required defaults:

- 8 GB NeoForge memory allocation
- Pummelchen multiplayer server entry
- BSL active shader
- Complementary Reimagined available
- ModernArch resource packs active and ordered:
  1. `ModernArch Denser Grass Addon`
  2. `ModernArch FA Extension`
  3. `ModernArch v2.8.2 [26.1] [128x]`
- compatible ModernArch packs must not remain in the incompatible list
- `duck_tamed_no_follow = true`
- `goose_tamed_no_follow = true`

## Release Creation

Releases are immutable directories named `release_<YYYYMMDD>_V<N>[_label]`.

Pack artifact names are version-scoped. For Minecraft `26.1.2`, the generated client ZIP is `minecraft_26.1.2_client_macos_apple_silicon.zip` and the MRPack is `pummelchen-server-26.1.2.mrpack`; newer Minecraft versions must use their own matching artifact names.

Each release contains:

- `CHANGELOG.md`
- `metadata.json`
- `manifests/server-files.tsv`
- `manifests/client-package.tsv`
- `server-files/mods`
- `server-files/server-datapacks`
- `client-package`
- `artifacts`
- `db/pummelchen.duckdb`
- `public/client-sync-manifest.tsv`
- `public/client-files`

Activation always publishes static release files through nginx and writes version-scoped current release files such as `/downloads/current-release-26.2.json` and `/downloads/current-release-minecraft_26_2.json`.

Only the Minecraft version marked `is_live = true` in DuckDB may also update `/downloads/current-release.json`, `/downloads/current-release.txt`, and the stable DMG/download aliases used by normal clients. Staging versions must not overwrite the global current release pointer.

After activation, the Swift release pipeline enforces storage retention. It keeps the active release plus the newest retained releases per `server_key` in DuckDB and prunes older release directories from both the private release root and nginx public download release root. Manual VPS cleanup must not be the only disk-space control.

`current-release.json` is also the client-app self-update contract. When a release includes a macOS DMG, the payload must include both:

- `dmg_url`
- `dmg_sha256`

The DMG URL must stay inside `/downloads/releases/<release-id>/` and the SHA256 must match the exact published `MCPummelchenModClient.dmg`. Clients use this metadata to stage a verified app update, replace `MCPummelchenModClient.app`, and relaunch automatically when the installed app bundle `PummelchenReleaseID` differs from the server `release_id`.

## Manifest Format

`public/client-sync-manifest.tsv` is a UTF-8 TSV file:

```text
# Pummelchen client sync manifest v1
# section	name	size	sha256	url_path
<section>	<name>	<size_bytes>	sha256:<64 lowercase hex>	downloads/releases/<release-id>/client-files/<section>/<name>
```

Allowed sections:

- `mods`
- `resourcepacks`
- `shaderpacks`
- `tools`

## Server Health Checks

Server health must cover:

- Minecraft service state
- RCON or server ping where available
- active release pointer
- release download availability
- disk space
- datapack presence
- generated site status files

## Release Health Checks

Release health must verify:

- the version-scoped current-release JSON exists and points to the active release
- global current-release JSON is updated only when the release Minecraft version is marked live in DuckDB
- client manifest exists and parses
- every manifest entry resolves through nginx
- every downloaded file matches size and SHA256
- ZIP/MRPack/DMG checksum files match artifacts
- active DB release row matches published release

## DMG New-Player Acceptance And Live Soak Gate

Every new `MCPummelchenModClient.dmg` must be tested before release activation by installing from that exact DMG into an isolated fresh-player environment, repairing/installing the managed Java runtime, installing NeoForge, syncing the full client pack, applying client defaults, validating the local client DuckDB, adding the Pummelchen server entry exactly once, logging into the live Pummelchen Minecraft server, and staying connected for at least 1 minute.

The Swift runner that produces this proof is:

```text
pummelchen-headless-soak --dmg <MCPummelchenModClient.dmg> --release-id <release_id> --server-address 91.99.176.243:25565
```

The runner mounts the DMG, copies the macOS app into an isolated work directory, validates the app bundle/signature/helper binary/embedded DuckDB dylib, runs the bundled `pummelchen-client-sync` helper, verifies managed Java and NeoForge, verifies every manifest file by size and SHA-256, checks all managed client defaults with the same inspector used by the GUI, prepares HeadlessMC plus HMC-Specifics, launches NeoForge with `--quickPlayMultiplayer`, scans the isolated logs/crash reports, and writes the release-gate report beside the DMG. The built-in runner defaults to `--suppress-gui true`: it does not send HeadlessMC GUI display commands and requests a small 320x240 window if a renderer fallback still appears. Use `--suppress-gui false` only when visual debugging is required. `--headless-command` remains available only as an override. The default HeadlessMC home is `~/Library/Application Support/Pummelchen/headlessmc` so the Minecraft account login can persist while every soak still uses a fresh isolated Minecraft game directory.

The macOS DMG builder can invoke this automatically when these environment variables are set:

- `PUMMELCHEN_RELEASE_ID`
- `PUMMELCHEN_HEADLESS_COMMAND` only when overriding the built-in HeadlessMC launcher
- `PUMMELCHEN_REQUIRE_HEADLESS_SOAK=true` for production builds that must fail if the soak is not configured

The release pipeline hard-requires this proof file next to the DMG:

```text
MCPummelchenModClient.dmg.headless-live-soak.json
```

The report must prove:

- `release_id` matches the release being created
- `dmg_sha256` matches the generated DMG
- `server_address` targets the live Pummelchen server on port `25565`
- `installed_from_dmg`, `java_ok`, `neoforge_ok`, `sync_ok`, `login_ok`, and `stayed_connected` are all `true`
- `duration_seconds` is at least `60`
- `crash_report_count` and `fatal_log_count` are `0`
- `new_player_setup.status` is `passed`
- `new_player_setup.defaults_ok` is `true`
- `new_player_setup.manifest_entries` is greater than `0`
- `new_player_setup.verified_managed_files` equals `new_player_setup.manifest_entries`
- `new_player_setup.server_entry_count` is exactly `1`
- `status` is `passed`
- `started_at` and `completed_at` are ISO-8601 timestamps

If the report is missing, stale, too short, points at the wrong DMG or server, lacks the new-player setup acceptance block, records a setup failure, or records a crash/fatal log, the Swift release pipeline must reject the DMG release. Passed reports are recorded in DuckDB `core.headless_client_runs`.

## Mod Source Update Scans

The Swift server app owns repository update discovery. Source URLs are stored in DuckDB, not inferred only from website JSON.

Required behavior:

- store one row per mod/source URL in `core.mod_sources`
- support more than one URL per mod, such as Modrinth and CurseForge
- persist each scan in `core.mod_update_scans`
- persist per-URL outcomes in `core.mod_update_scan_results`
- throttle webpage/API fetching; production default is at most 5 URLs per 10 seconds
- prefer official API/hash metadata when available
- allow page crawling with curl-equivalent HTTP requests for stored URLs
- classify Cloudflare/challenge pages as blocked or unresolved instead of treating them as valid update data
- never auto-promote a scraped update candidate without the normal validation and release flow

## Release History API Shape

The public website no longer uses a static `tested-updates.json` feed. Release/update history is served by the Swift app from DuckDB through API endpoints such as `/api/v1/site/release-history`, `/api/v1/site/update-activity`, and `/release.html?release=<release_id>`.

`/api/v1/site/release-history` returns a DuckDB-backed object:

- `api_version`
- `generated_at`
- `generated_by`
- `source`
- `cutoff_days`
- `total_entries`
- `updates`

Each update row is generated from `release.pack_releases` and must include stable fields for release-history rendering:

- timestamp (`tested_at`)
- title
- event type
- source
- status
- source URL pointing to `release.html`
- notes/details when known

Static website JSON fallbacks are not allowed for current release history, mod inventory, failed mods, server-version data, or live stats. If DuckDB or the Swift app cannot provide real data, the API should fail and the browser should show an unavailable state instead of stale placeholders.

Parser helpers may return `nil` or `[]` only for local optional parsing cases such as "no regex match", "missing optional NBT field", "no optional manifest candidate", or "empty folder". Production-facing data source failures, DuckDB query failures, release activation failures, checksum failures, and client repair failures must be explicit errors or explicit status rows, not silent fallbacks.

## Failed Mods Feed Shape

The failed-mods page/table must include:

- timestamp as first column in `YYYY-MM-DD HH:MM:SS`
- mod/title
- URL/source
- file/version when known
- failure reason
- details column with actionable context

## Safe World Reset Behavior

Safe reset is destructive and must only run through the audited Swift server app workflow.

Required behavior:

- dry-run support
- explicit seed write
- old world moved/backed up before deletion
- required datapacks installed before first boot
- gamerules enforced:
  - keep inventory
  - no mob griefing
  - block interactions/mob explosions/TNT explosions must not destroy blocks
  - all blocks drop loot where relevant gamerules support it
- bonus chest enabled and customized
- spawn detected
- 1000-block radius pregenerated
- no leftover force-loaded chunks
- backup cleanup only after successful new-world health check
