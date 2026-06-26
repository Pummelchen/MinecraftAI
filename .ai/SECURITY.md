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
# Security and Safety Guide

This repository manages executable downloads, privileged services, a live Minecraft process, client filesystem mutation, and production database state. Treat security controls as functional requirements.

## 1. Sensitive asset inventory

| Asset | Examples/locations | Required handling |
|---|---|---|
| Repository access credentials | Git access tokens, deployment credentials | Never print, log, commit, write to generated docs, or embed in remotes. |
| Client bootstrap/reporting credentials | `PUMMELCHEN_CLIENT_API_TOKEN`, optional bundled `client-api-token` | Use environment/private resource handling; never public metadata or diagnostics. |
| Client identity secrets | intended `client_secret` / Keychain identity model in contracts | Never log or store in public DuckDB/site/release artifacts. |
| RCON credential | `PUMMELCHEN_MINECRAFT_RCON_PASSWORD`, `--rcon-password` | Keep out of commands shared in issues/docs/history; restrict RCON to localhost/firewall. |
| Server environment | `/etc/pummelchen-swift/server.env` | Runtime-only; do not reconstruct, copy, or commit values. |
| TLS key material | Let's Encrypt private key paths in nginx config | Never copy into repo or artifacts. |
| Production DuckDB | runtime DB and backups | Contains operational/client/release/audit state; back up and use migrations. |
| Executable artifacts | app, helper, DMG, ZIP, JAR, MRPACK | Verify source, size/SHA, bundle/native structure, and release gates. |
| Live world | Minecraft world directory and backup | Destructive operations require explicit confirmation and recovery plan. |

## 2. Current authentication conflict

This is the most important unresolved security fact.

### Current source behavior

- The API route switch handles control/client write endpoints without calling the former authorization guard.
- `ClientControlChannel` sends `X-Pummelchen-Client-ID` and adds `Authorization: Bearer ...` only when an optional token exists.
- `ClientControlWatcher` can poll and acknowledge events without a token.
- `ClientSyncEngine.report` still exits early when no token exists, so client status/inventory/defaults uploads are not attempted in that case.
- `/api/v1/status` still derives a mode string from whether the server config has a token, despite route-level authorization no longer being enforced.

### Current documentation behavior

- `CLIENT_IDENTITY.md` describes authenticated write/report and control traffic using a client secret.
- README/production wording still describes authenticated HTTPS control APIs.
- DMG code still supports bundling a private bootstrap resource.

### Security implication

Do not assume either “all client APIs are intentionally public” or “authentication is enforced.” The implementation is asymmetric and the docs are stale relative to code.

A proper change requires an explicit threat-model decision covering:

1. Which endpoints are public read-only, client-authenticated, or operator-only.
2. Whether `X-Pummelchen-Client-ID` is only an identifier or an authorization signal.
3. Enrollment, rotation, revocation, and migration for existing clients.
4. Protection of control-event creation versus polling/acknowledgement.
5. Whether nginx adds access control or rate limiting.
6. Backward compatibility for tokenless clients.
7. Status-mode semantics, tests, and documentation.

Mark all opportunistic auth edits `needs_human_review`.

## 3. Public network boundary

### nginx controls

Verified configuration includes:

- TLS 1.2/1.3.
- HTTP/2 and HTTP/3.
- public hostnames and certificate paths.
- `/api/` proxy to `127.0.0.1:8787`.
- 256 KiB proxied request-body limit.
- forwarding of host and client IP headers.
- no-store headers for API/operational responses.
- static `/downloads/` with no directory listing and security headers.
- no-cache current-release pointer handling.

### Rules for AI changes

- Keep the Swift server locally bound unless the deployment architecture intentionally changes.
- Do not proxy large artifacts through API handlers.
- Preserve no-store semantics for mutable operational data and current pointers.
- Preserve `X-Content-Type-Options`, frame, and referrer controls on downloads/site where configured.
- Review every new nginx alias for path traversal, caching, content type, and stale-data impact.
- Do not commit certificate/private-key material.
- Do not claim deployed TLS/firewall correctness from tracked config alone.

## 4. API input and output security

### Existing controls

- Explicit route and method matching.
- Payload-size errors.
- Codable/contract validation.
- client ID validation.
- bounded control fields and payload.
- no download references in control events.
- release/manifest path validation.
- safe SQL literal construction in inspected code paths.
- no-store operational response headers.

### Change checklist

For a new endpoint or field:

- [ ] Bound request size and collection counts.
- [ ] Validate strings, IDs, paths, URLs, and timestamps.
- [ ] Avoid returning server filesystem paths unless explicitly required.
- [ ] Do not echo secrets or raw authorization headers.
- [ ] Decide authentication/authorization explicitly.
- [ ] Use parameter-safe/escaped SQL patterns consistent with the current DB wrapper.
- [ ] Add method/error tests.
- [ ] Review website/client consumers for unsafe HTML rendering.
- [ ] Set appropriate cache headers.

## 5. Release and artifact supply-chain security

### Trust chain

```text
provider metadata/artifact
  -> compatibility and source checks
  -> file hash / JAR inspection / optional version patch
  -> managed server/client package
  -> immutable release manifests and checksums
  -> optional DMG and acceptance proof
  -> nginx static publication
  -> client release/manifest/hash validation
  -> atomic installation
```

Each stage is a security control. Do not bypass a later gate because an earlier stage passed.

### Required rules

- Source discovery is not trust approval.
- Provider HTML scraping can be blocked or ambiguous; classify unresolved rather than guessing.
- Verify artifact hashes whenever the contract provides one.
- Preserve JAR/ZIP path and metadata checks.
- Keep release directories immutable.
- Validate public release paths and current-release URLs.
- Keep global aliases live-version-only.
- Never publish a DMG without its matching checksum and required soak proof.
- Never reuse a soak proof for a different DMG hash or release ID.
- Do not weaken retention in a way that removes the active/recovery release.

## 6. Client filesystem boundary

The client writes into the user's Minecraft directory and Pummelchen application support area.

### Existing controls

- `SafePath` validation.
- manifest section allowlist.
- plain filename validation.
- no hidden/relative/path-containing manifest names.
- release-scoped URL requirement.
- size/SHA256 validation.
- temporary download and post-download verification.
- atomic replacement.
- stale removal based on the previous managed manifest.
- unmanaged quarantine only on first install.
- Minecraft-running guard.

### Rules for changes

- Never derive a destination directly from an unvalidated remote path.
- Never add an arbitrary manifest section without a fixed destination map.
- Keep replacement on the same filesystem where possible for atomic behavior.
- Do not delete files merely because they are absent from the new manifest unless they were tracked as previously managed.
- Preserve player preferences on repeat sync.
- Use disposable Minecraft directories in development.
- Avoid recording full local paths or user-identifying data in public diagnostics.

## 7. Client self-update security

Self-update replaces executable application code.

Required controls:

- validated current-release metadata;
- paired DMG URL and SHA;
- stable or release-scoped allowed URL;
- full DMG hash verification;
- read-only mount;
- app bundle, helper, signature, and embedded DuckDB validation;
- release ID comparison;
- controlled staging/relaunch;
- no update from untrusted arbitrary URL.

Do not simplify self-update to “download and copy.” Add tests for every new bypass or fallback path.

## 8. DMG credential handling

`ClientDMGBuilder` can write an optional `client-api-token` resource into the staged app and sets mode `0600` before signing.

Rules:

- Never commit a real resource file.
- Never include the value in build logs, command-line arguments, diagnostics, current release JSON, website data, or checksums metadata beyond the artifact hash.
- Use a controlled private build environment.
- Inspect packaging code when changing app resources to ensure the token is not copied to a public location outside the signed app.
- Reevaluate whether the bootstrap resource is still required after resolving the authentication conflict.

## 9. DuckDB security and integrity

### Risks

- Production data loss or schema drift.
- Accidental mutation by a test/development command.
- Exposure of client inventory/diagnostics.
- Write contention.
- stale reporting views.
- unreviewed raw SQL changes.

### Rules

- Always use a disposable DB for development migration/health tests.
- Back up production before migration or repair.
- Add a new numbered migration; retain checksums/history.
- Keep transactions around migration application.
- Review queries for correct escaping and type handling.
- Avoid exposing raw client diagnostics through public endpoints.
- Preserve the scheduled exclusive-write scan pattern unless concurrency is redesigned.
- Treat `Live Backup/` as sensitive recovery state, not fixture data.

## 10. systemd and privilege boundary

The server service is root-owned and can execute systemctl/firewall/process operations.

### Existing controls

- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectHome=true`
- `ProtectSystem=full`
- `RestrictSUIDSGID=true`
- limited `ReadWritePaths`
- localhost API bind
- root-only runtime environment file

### Rules

- Do not remove hardening to solve a path/permission issue without determining the minimal required access.
- Do not widen `ReadWritePaths` broadly.
- Review all subprocess arguments for injection and secret leakage.
- Preserve explicit executable paths for privileged commands.
- Understand `KillMode=process` before changing it.
- Keep RCON firewall behavior local-only.
- Treat service/timer changes as deployment/security changes requiring human review.

## 11. Minecraft RCON and watchdog

RCON permits commands against the live server.

Existing safety:

- default host is localhost;
- firewall rules block non-local RCON;
- password is environment/server-properties driven;
- watchdog commands/timeouts/failure thresholds are configurable;
- error logs redact secrets in inspected supervisor logic.

Rules:

- Never log the RCON password or include it in shared command examples.
- Keep RCON port validation.
- Do not expose RCON through nginx or public interfaces.
- Treat watchdog restart behavior as availability-sensitive.
- Test command parsing with benign commands.
- Do not add arbitrary shell interpretation around RCON command inputs.

## 12. World reset safety

World reset is the highest-impact workflow.

Mandatory invariants:

- dry-run plan available;
- explicit destructive confirmation;
- validated world name/path;
- service control validation;
- backup before mutation;
- required datapack verification;
- RCON readiness;
- safety gamerules;
- bounded pregeneration batching;
- forceload cleanup verification;
- persisted requested/running/completed/failed state;
- optional backup deletion only after success and explicit configuration.

Never run a real reset to test a code change. Use pure calculation tests, fixtures, and dry-run.

## 13. External provider and network risk

The scanner and installers access external services:

- Modrinth
- CurseForge
- NeoForged Maven/site
- filtered search results
- Temurin GitHub releases

Rules:

- Pin and verify executable/archive hashes where supported.
- Treat HTML parsing as fragile and untrusted.
- Enforce provider rate limits.
- Do not accept Cloudflare/challenge/error pages as version data.
- Sanitize/log only non-sensitive request context.
- Keep external network out of deterministic unit tests.
- Do not auto-deploy a discovered update.

## 14. Website data and browser security

The site renders DB/API-provided mod/release/client-derived data.

Review for:

- HTML injection when assigning values;
- unsafe URL construction;
- opening external links with `rel="noopener"` where appropriate;
- stale or cached operational data;
- exposing internal paths, diagnostics, or client identity details;
- third-party CDN dependency availability/integrity decisions.

Operational API failure should render “unavailable,” not stale fabricated data.

## 15. Logging and diagnostics

Logs may include:

- source URLs and artifact names;
- release IDs;
- client IDs;
- filesystem paths;
- error output from external tools;
- network/installer details.

Rules:

- redact credentials and authorization headers;
- avoid logging raw private app resources;
- cap diagnostic snippets and payloads;
- avoid public exposure of user home paths or personally identifying hostnames;
- distinguish safe client ID from secret;
- inspect subprocess error output before including it in a public/API response.

## 16. Generated-file secret scan

Before distributing docs or committing generated onboarding files:

- scan for token prefixes, bearer headers, private key markers, RCON password assignments, and credential-like high-entropy strings;
- verify examples use `<secret>` placeholders;
- verify manifest source lists contain paths only, not content;
- inspect ZIP contents before sharing;
- never print the secret used as the scan needle.

## 17. Security review triggers

Require explicit human security review for:

- authentication/authorization changes;
- new public API write endpoint;
- client identity or credential storage;
- executable download/update changes;
- checksum/signature bypass or fallback;
- nginx public route/proxy/cache changes;
- systemd privilege/hardening changes;
- new filesystem write roots;
- production DB migration/repair;
- RCON/firewall/watchdog changes;
- world reset/backup behavior;
- release activation/live-version rules;
- diagnostic/log expansion.

## 18. Security checklist for a PR

- [ ] No secrets/private runtime data in diff, tests, fixtures, or logs.
- [ ] Inputs have explicit bounds and validation.
- [ ] Paths stay inside intended roots.
- [ ] Hash/signature validation preserved.
- [ ] Authentication decision is explicit and tested.
- [ ] Public versus private data classified.
- [ ] DB change uses migration and disposable validation.
- [ ] Privileged subprocesses use fixed executables and safe arguments.
- [ ] Dry-run/confirmation retained for high-impact operations.
- [ ] Website/client downstream consumers reviewed.
- [ ] Production-only acceptance is listed, not falsely claimed.

## Evidence

- `Server App/Docs/contracts/CLIENT_IDENTITY.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ControlEventStore.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/ClientDMGBuilder.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/SwiftReleasePipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/SwiftWorldResetPipeline.swift`
- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MinecraftLiveServerSupervisor.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientSyncEngine.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientControlChannel.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientAppSelfUpdater.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/CurrentRelease.swift`
- `Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/ClientSyncManifest.swift`
- `Server App/nginx/sites-available/pummelchen-swift.conf`
- `Server App/systemd/MCPummelchenModServer.service`
