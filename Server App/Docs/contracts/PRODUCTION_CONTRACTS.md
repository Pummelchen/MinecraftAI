# Pummelchen Production Contracts

This document freezes the production behavior that the Swift/DuckDB migration must preserve before replacing any script.

## Project Location

The Swift migration lives in `swift/PummelchenSwift`.

Reason:

- It keeps the new Swift code isolated from live Python/Bash operations.
- It allows SwiftPM build/test gates without changing production behavior.
- It can later produce both the Debian server service and the macOS client app from shared contract code.

The client identity/token model is frozen in `docs/contracts/CLIENT_IDENTITY.md`.

## Updater Flow

1. Client resolves `/downloads/current-release.json`.
2. Client reads `release_id` and `manifest_url`.
3. Client downloads `/downloads/releases/<release-id>/client-sync-manifest.tsv`.
4. Client compares each listed file by path, size, and SHA256.
5. Client downloads only missing or changed files.
6. Downloads must use temporary files, verify SHA256, then atomically replace the final path.
7. If no files need download, the client must still show or print a useful all-synced summary.

## Manual Repair One-Liner

The website must keep a copyable manual repair command until the Swift client has proven real-world recovery:

```sh
curl -fsSL http://91.99.176.243:7788/downloads/pummelchen-auto-update.sh -o "$HOME/Library/Application Support/Pummelchen/bin/pummelchen-auto-update.sh" && chmod +x "$HOME/Library/Application Support/Pummelchen/bin/pummelchen-auto-update.sh" && "$HOME/Library/Application Support/Pummelchen/bin/pummelchen-auto-update.sh" --force
```

The Swift CLI helper can replace the downloaded script only after the same command path recovers at least one broken client install.

## Client No-Download Summary

When nothing needs download, the manual updater and future Swift CLI must report:

- server release ID
- installed/client release ID
- verified file count
- changed file count of `0`
- clear all-synced/no-downloads-required message

## DMG Contents

Current legacy DMG contents must remain functionally available during migration:

- installer entrypoint
- client tools/updater
- client manifest
- resource packs
- shader packs
- default configs
- Pummelchen server entry setup

The future DMG will install `PummelchenClient.app`, but it must keep CLI repair functionality inside the app bundle.

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

Activation publishes static files through nginx and writes `/downloads/current-release.json` plus `/downloads/current-release.txt`.

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

- current-release JSON exists and points to the active release
- client manifest exists and parses
- every manifest entry resolves through nginx
- every downloaded file matches size and SHA256
- ZIP/MRPack/DMG checksum files match artifacts
- active DB release row matches published release

## Tested Updates Feed Shape

`/tested-updates.json` returns an object:

- `generated_at`
- `cutoff_days`
- `total_entries`
- `updates`

Each update row must include stable fields for table rendering:

- timestamp (`tested_at`, displayed as `YYYY-MM-DD HH:MM:SS` in future table views)
- title
- event type
- source
- status
- old file
- new file
- version
- source URL when known
- notes/details when known

## Failed Mods Feed Shape

The failed-mods page/table must include:

- timestamp as first column in `YYYY-MM-DD HH:MM:SS`
- mod/title
- URL/source
- file/version when known
- failure reason
- details column with actionable context

## Safe World Reset Behavior

Safe reset remains destructive and must only run through an audited job queue in the future.

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
