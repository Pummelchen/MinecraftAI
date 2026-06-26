<!--
AI onboarding file.
Mode: refresh
Indexed commit: 00e25e1a9584ca075e27b404305bda18157aa7f3
Last generated: 2026-06-25T22:08:15+02:00
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# Known Unknowns, Conflicts, and Human-Review Areas

This file is intentionally explicit. Future agents should not “clean up” these items by guessing.

## Priority conflicts

### 1. Client/control API authentication

**Status:** `conflicting`, `needs_human_review`, security-sensitive.

**Current code evidence**

- The API route switch no longer calls the former authorization guard for control/client write endpoints.
- `ClientControlWatcher` polls without requiring a token.
- `ClientControlChannel` makes the token optional and sends Authorization only when present.
- `ClientSyncEngine.report` still returns without uploading when a token is absent.
- Server status mode is still derived from token configuration.

**Documentation evidence**

- `Server App/Docs/contracts/CLIENT_IDENTITY.md` says control and write/report traffic must authenticate with bearer client secrets.
- README and production wording still refer to authenticated live update control APIs.
- DMG code still supports a private bootstrap credential resource.

**Why this matters**

Current behavior creates an asymmetric state: control polling/acknowledgement and server write handlers can be reached without the client report path actually sending tokenless reports. The repository does not clearly establish the intended public/operator/client trust model after the auth-removal commit.

**Required human decision**

Define endpoint-by-endpoint authorization, enrollment/rotation/revocation, legacy-client compatibility, nginx responsibilities, and status-mode semantics. Then update code, tests, contracts, README, and this onboarding system together.

### 2. Server status `mode` field

**Status:** `conflicting/stale`.

`/api/v1/status` reports `read_only` when `clientAPIToken` is nil and `phase6_writes_enabled` otherwise. Current route handling no longer uses the token to gate the write endpoints, so the mode name may not represent actual capability or security.

Do not build new logic on this field until its intended meaning is clarified.

### 3. Swift version descriptions

**Status:** `conflicting but probably compatible`.

- Package manifests declare `// swift-tools-version: 6.2`.
- `Server App/Database/duckdb/README.md` mentions a host with Swift 6.3.2.

A newer compiler can satisfy a lower tools-version manifest, but the deployment toolchain is not pinned by a version file in the inspected repository. Verify the actual supported developer/deployment toolchain before changing platform/compiler requirements.

## Production facts not verifiable from Git

### Deployment state

Unknown:

- whether tracked nginx/systemd files exactly match deployed files;
- active service/timer status;
- current environment-file values;
- certificate expiration/status;
- DNS and IPv6 reachability;
- firewall state;
- free disk space and retention effectiveness;
- current binary versions under `/opt/pummelchen-swift/bin`.

Use operator/host evidence for these facts.

### Live database state

Unknown:

- exact live schema migration version;
- data quality and row counts;
- currently live/staging version rows;
- active release and health rows;
- client registration/inventory/diagnostic data;
- scan backlog and failed provider state;
- whether `Live Backup/` exactly matches current production.

Do not infer live DB state from schema or backup filenames.

### Live release/runtime files

Unknown:

- exact current-release JSON and aliases deployed;
- active immutable release directories;
- current DMG/MRPACK/ZIP artifacts and checksums;
- soak reports and account state;
- live server package/mod directory contents;
- live world/backup state.

### External services

Unknown/unstable:

- current Modrinth/CurseForge APIs and HTML;
- provider rate limits and Cloudflare behavior;
- current NeoForged metadata;
- Temurin download availability;
- Tabulator CDN availability;
- current Minecraft/NeoForge compatibility of each mod;
- current public endpoint latency/availability.

These require current network validation and should not be hard-coded from stale observations.

## Repository areas not exhaustively inspected

The onboarding refresh performed a deep targeted scan of package manifests, entrypoints, central pipelines, shared contracts, DB docs/migrations, nginx/systemd, website pages, and test inventory. The following were not exhaustively interpreted line by line:

- every helper/private method in very large server core and pipeline files;
- all HTML/CSS/JavaScript implementation details on every page;
- every SQL statement in every migration;
- binary contents in `Live Backup/` and image assets;
- the entire vendored DuckDB header;
- external project wiki content.

Future task-specific work must inspect the exact current files rather than relying on this map.

## CI, lint, and formatting

**Status:** `unknown/absent in inspected tree`.

No GitHub Actions workflow, dedicated lint command, or formatter configuration was found. Do not assume remote CI will run. If a workflow exists outside the inspected branch/path, update this file after verification.

## Test and acceptance limitations

- The commands in onboarding docs were derived from source/manifests/docs; they were not run while producing the ZIP.
- Native DuckDB availability was not verified in the artifact-generation environment.
- macOS DMG/codesign builds were not run.
- live nginx/systemd/Minecraft/RCON checks were not run.
- live headless soak was not run.
- external provider scans were not run.

These are not failures; they are explicitly skipped validations.

## Ambiguous ownership or policy

### Authentication policy owner

Not documented. Security/operations maintainers should own the decision.

### Production release approval

Code enforces gates, but the human role responsible for promoting staging to live is not identified in the repository.

### Backup retention policy

Release retention has a code default, and README describes in-repo DB backups, but long-term backup retention, encryption, offsite storage, and restore testing are not specified.

### Provider source policy

Code supports official/provider/direct/search discovery, but maintainer policy for accepting a weakly discovered source versus requiring a primary official link is not fully documented.

### Client privacy policy

The API models include client inventory, diagnostics, IP/log information, OS/architecture, and status. Retention, access control, and privacy policy are not documented in the inspected repo.

## Potential stale or misleading statements

| Statement/area | Why review is needed |
|---|---|
| README “authenticated HTTPS live update control APIs” | Current route code removed hard auth checks. |
| `CLIENT_IDENTITY.md` “No unauthenticated client write APIs” | Contradicted by current route dispatch. |
| Server status mode names | Tied to configured token, not actual route gating. |
| Swift 6.3.2 host wording | Not a package toolchain pin. |
| Hard-coded default URLs/version examples | May be bootstrap defaults rather than current production truth. |
| Platform version examples | Minecraft versions and installer metadata are server/DB-driven and may evolve. |

## Model-specific AI files

No standard model-specific instruction files were found at the checked locations during the original bootstrap and refresh analysis:

- root `CLAUDE.md`
- `.github/copilot-instructions.md`
- `.ai/GPT-*`
- `.ai/CLAUDE*`
- `.ai/QWEN*`
- `.ai/GEMINI*`
- `.ai/GLM*`
- `.ai/DEEPSEEK*`
- `.ai/OTHER-AI.md`

No migration, deprecation, preservation, or deletion is required based on the inspected state. Re-scan before a future refresh because new files may be added.

## Ask a human before editing or running

Always obtain explicit direction for:

- resolving authentication/authorization;
- changing client identity/credential storage;
- exposing a new public write endpoint;
- production DuckDB migration or repair;
- deleting/rewriting `Live Backup/`;
- changing which Minecraft version is `is_live`;
- activating a release or changing stable aliases;
- changing DMG credential packaging;
- weakening checksum/signature/soak validation;
- nginx TLS/public routing/cache changes;
- systemd privilege/hardening/write-path/kill-mode changes;
- RCON/firewall/watchdog behavior;
- real world reset or backup deletion;
- live mod apply/add/ban outside dry-run;
- provider scraping policy or automatic promotion behavior;
- collection/retention/exposure of client diagnostics and inventory.

## Facts intentionally marked inferred

- The repository behaves like a multi-component operations platform rather than a conventional monolith. This is inferred from the independent CLI/API/client/DB/edge/service surfaces.
- The daily scan stop/restart pattern is intended to avoid DuckDB write contention. This is inferred from service documentation and command sequencing.
- `Live Backup/` may contain sensitive operational/client data because it is a production DB snapshot; exact content was not inspected.
- Some website field mappings may rely on API properties not captured in this onboarding summary; inspect JavaScript before changing payloads.

## Refresh follow-up triggers

Update this file immediately when:

- authentication is resolved;
- a CI/lint/format workflow is added;
- production toolchain is pinned;
- deployment state is codified;
- backup/privacy/approval policy is documented;
- routes or client data collection change;
- a stale statement above is corrected.

## Evidence

- current server API route code
- current client control/report code
- `Server App/Docs/contracts/CLIENT_IDENTITY.md`
- `README.md`
- package manifests and DuckDB README
- nginx/systemd tracked configuration
- current onboarding diff and manifest
