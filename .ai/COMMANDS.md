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
# Commands

Run from the repository root unless a section says otherwise. Paths contain spaces; quote them. Commands with `<placeholder>` values are templates, not copy-paste production commands.

## Safety legend

| Label | Meaning |
|---|---|
| SAFE | Read-only or local build/test operation. |
| DISPOSABLE | Writes only to an explicitly disposable/local path. |
| DRY-RUN | Pipeline resolves/plans but is configured not to perform intended mutation. Verify the command's current dry-run implementation before relying on it. |
| OPERATOR | May modify package state, runtime files, DB records, artifacts, or service state. Requires an explicit target. |
| DESTRUCTIVE | Can remove/replace live state. Use only with explicit authorization and backups. |

## Prerequisites and toolchain checks

Package manifests declare Swift tools version `6.2` and macOS platform `26.0`. The DuckDB README mentions a host with Swift `6.3.2`; a compatible newer toolchain may be used, but do not change manifest requirements based only on host documentation.

```sh
# SAFE
swift --version

# SAFE: verify the native DuckDB library path expected by the local host.
# The shared package defaults to /opt/homebrew/lib on macOS and /usr/local/lib elsewhere.
# Override only for the current command/session if needed:
export PUMMELCHEN_DUCKDB_LIB_DIR="<directory-containing-libduckdb>"
```

There is no external package-manager install step in the inspected manifests; dependencies are local Swift packages. Native DuckDB must be installed and linkable.

## Build / typecheck

Swift build is the repository's practical compile/typecheck command.

```sh
# SAFE
swift build --package-path "Server App/MCPummelchenModShared"

# SAFE
swift build --package-path "Client App/MCPummelchenModClient"

# SAFE
swift build --package-path "Server App/MCPummelchenModServer"
```

Recommended dependency order when diagnosing failures:

1. shared package;
2. client package;
3. server package.

Release product builds used by the DMG builder:

```sh
# SAFE but produces .build output; macOS for GUI product.
swift build -c release \
  --package-path "Client App/MCPummelchenModClient" \
  --product MCPummelchenModClient

swift build -c release \
  --package-path "Client App/MCPummelchenModClient" \
  --product pummelchen-client-sync
```

## Tests

### All package tests

```sh
# SAFE; requires native DuckDB for DB-backed tests.
swift test --package-path "Server App/MCPummelchenModShared"

swift test --package-path "Client App/MCPummelchenModClient"

swift test --package-path "Server App/MCPummelchenModServer"
```

### Focused tests

SwiftPM `--filter` accepts suite/test identifiers. Confirm the exact discovered name if a filter returns no tests.

```sh
# SAFE examples
swift test \
  --package-path "Server App/MCPummelchenModShared" \
  --filter CurrentReleaseTests

swift test \
  --package-path "Server App/MCPummelchenModShared" \
  --filter ClientSyncManifestTests

swift test \
  --package-path "Client App/MCPummelchenModClient" \
  --filter ClientSyncEngineTests

swift test \
  --package-path "Client App/MCPummelchenModClient" \
  --filter ClientStatusTests

swift test \
  --package-path "Client App/MCPummelchenModClient" \
  --filter ClientAppSelfUpdaterTests

swift test \
  --package-path "Client App/MCPummelchenModClient" \
  --filter MinecraftClientDefaultsTests

swift test \
  --package-path "Server App/MCPummelchenModServer" \
  --filter MCPummelchenModServerCoreTests
```

## Run the server locally

The API reads release/public files relative to `--project-root`. A plain checkout may not contain runtime-generated current release files, so some endpoints/smoke checks can return not-found until a fixture/runtime tree is supplied.

```sh
# SAFE with respect to production only when project root points to a local checkout/fixture.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer serve \
  --project-root "$PWD" \
  --host 127.0.0.1 \
  --port 8787
```

Smoke-check the current release and manifest:

```sh
# SAFE/read-only against the specified project root.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer smoke \
  --project-root "<runtime-or-fixture-root>"
```

## Server command catalogue

The following usage is grounded in `Sources/MCPummelchenModServer/main.swift`. Re-read that file before scripting commands because flags can evolve.

### Create a release

```sh
# OPERATOR: creates release files and DB rows; --activate may publish/restart.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer release-create \
  --project-root "<project-root>" \
  --server-dir "<version-server-dir>" \
  --release-root "<private-release-root>" \
  --public-downloads "<nginx-download-root>" \
  --duckdb "<duckdb-file>" \
  --release-id "<release-id>" \
  --activate false \
  --service "<optional-systemd-unit>"
```

Omit `--service` if no restart is intended. Keep `--activate false` while validating a staged release.

### Validate a release

```sh
# SAFE/read-only if the implementation does not invoke configured service/health mutation.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer release-validate \
  --project-root "<project-root>" \
  --server-dir "<version-server-dir>" \
  --release-root "<private-release-root>" \
  --public-downloads "<nginx-download-root>" \
  --duckdb "<duckdb-file>" \
  --release-id "<release-id>"
```

### Add a mod

```sh
# DRY-RUN: provider resolution/dependency inspection without package/release mutation.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer add-mod \
  --project-root "<project-root>" \
  --server-dir "<version-server-dir>" \
  --release-root "<private-release-root>" \
  --public-downloads "<nginx-download-root>" \
  --duckdb "<duckdb-file>" \
  --url "<curseforge-or-modrinth-url>" \
  --release-id "<release-id>" \
  --install-scope auto \
  --activate false \
  --dry-run true \
  --require-client-token false
```

Optional flags:

- `--server-package <dir>`
- `--service <systemd-unit>`
- `--local-artifact <jar>`
- `--install-scope auto|server|client|both`

Non-dry-run add-mod may copy artifacts, patch metadata, write DuckDB, build a DMG, create a release, and activate/restart if requested.

### Ban a mod

```sh
# DRY-RUN
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer ban-mod \
  --project-root "<project-root>" \
  --duckdb "<duckdb-file>" \
  --name "<display-name>" \
  --file-pattern "<jar-name-or-pattern>" \
  --source-url "<optional-source-url>" \
  --reason "Banned by Admin" \
  --dry-run true
```

Verify implementation before using `--dry-run false`; it may remove files and update policy/state.

### Patch one mod archive

```sh
# OPERATOR: modifies the archive in place.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer patch-mod \
  --jar "<path-to-jar-or-zip>" \
  --target-version "26.2"
```

Use a disposable copy first. The patcher invokes external `unzip`/`zip` and verifies the metadata after modification.

### Scan one or all supported versions

```sh
# DRY-RUN: avoid DB result writes; provider/network requests can still occur.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer mod-update-scan \
  --project-root "<project-root>" \
  --duckdb "<duckdb-file>" \
  --all-supported true \
  --seed-from-project-data true \
  --discover-source-links true \
  --discovery-searches-per-second 2 \
  --max-urls-per-window 5 \
  --window-seconds 10 \
  --dry-run true
```

Single-version alternatives/options:

- `--minecraft-version <version>`
- `--loader neoforge`
- `--discovery-limit <n>`
- `--limit <n>`

The tracked systemd unit runs all-supported scanning without `--dry-run true` and temporarily stops the API service for exclusive writes.

### Apply scanned updates

```sh
# DRY-RUN
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer mod-update-apply \
  --project-root "<project-root>" \
  --release-root "<private-release-root>" \
  --public-downloads "<nginx-download-root>" \
  --duckdb "<duckdb-file>" \
  --release-id-prefix "<release-prefix>" \
  --all-supported true \
  --dry-run true \
  --activate-live false \
  --require-client-token false
```

Optional:

- `--minecraft-version <version>` instead of all-supported
- `--server-package <dir>`
- `--service <systemd-unit>`

Non-dry-run can replace mod files, update DuckDB, build a DMG, create releases, activate a live release, and restart a service.

### Bootstrap a new Minecraft version

```sh
# DRY-RUN
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer server-version-bootstrap \
  --project-root "<project-root>" \
  --duckdb "<duckdb-file>" \
  --minecraft-version "<target-version>" \
  --reference-minecraft-version "<optional-reference-version>" \
  --discover-source-links true \
  --discovery-searches-per-second 2 \
  --max-urls-per-window 5 \
  --window-seconds 10 \
  --apply-updates false \
  --dry-run true \
  --require-client-token false
```

To hand off to update/release application, `--apply-updates true` also requires:

- `--release-root <dir>`
- `--public-downloads <dir>`
- `--release-id-prefix <id>`

Optional: `--server-package`, `--service`, `--discovery-limit`.

### Force a client update event

```sh
# OPERATOR: writes a control event.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer client-force-update \
  --project-root "<project-root>" \
  --duckdb "<duckdb-file>" \
  --release-id "<optional-release-id>" \
  --target-client-id "<optional-client-id>"
```

Omitting a target may create a global event; inspect current command implementation before use.

### Build a client DMG

```sh
# OPERATOR/macOS: builds executable artifacts, may run network/control/live-soak checks.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer build-client-dmg \
  --project-root "<project-root>" \
  --client-package "<client-package-dir>" \
  --server-package "<server-package-dir>" \
  --release-id "<release-id>" \
  --minecraft-version "<assigned-minecraft-version>" \
  --client-version "<client-version>" \
  --server-url "<https-server-url>" \
  --server-address "<minecraft-host:port>" \
  --duckdb-dylib "<libduckdb.dylib-path>" \
  --macos-deployment-target "26.0" \
  --skip-nginx-control-live-test true \
  --skip-headless-soak true \
  --require-headless-soak false \
  --headless-soak-seconds 60 \
  --require-client-token false
```

Optional:

- `--headless-command <command>`
- `--expected-installed-release-id <id>`

Production builds should not skip required gates. Credential values must come through supported private environment/resource handling, not committed commands.

### World reset

```sh
# DRY-RUN only; safe planning template.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer world-reset \
  --project-root "<project-root>" \
  --server-dir "<live-server-dir>" \
  --duckdb "<duckdb-file>" \
  --seed "<seed>" \
  --dry-run true \
  --yes false \
  --service "<minecraft-systemd-unit>" \
  --radius-blocks 1000 \
  --delete-backup-after-success false \
  --rcon-host 127.0.0.1 \
  --rcon-port 25575 \
  --rcon-ready-timeout-seconds 600 \
  --pregeneration-batch-size 384
```

**DESTRUCTIVE** execution uses `--dry-run false --yes true` and may accept `--rcon-password <secret>`. Do not place a real password in logs, docs, shell history, or a shared command. Use only with explicit live-target authorization and backup review.

### RCON command

```sh
# OPERATOR/possibly destructive depending on Minecraft command.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  MCPummelchenModServer rcon-command \
  --project-root "<project-root>" \
  --server-dir "<server-dir>" \
  --command "<minecraft-command>" \
  --rcon-host 127.0.0.1 \
  --rcon-port 25575
```

The command also accepts `--rcon-password <secret>`; prefer secure runtime configuration and never document the real value.

## Client commands

### GUI status app

```sh
# SAFE local run on macOS; may contact configured server.
swift run \
  --package-path "Client App/MCPummelchenModClient" \
  MCPummelchenModClient
```

One-shot status:

```sh
# SAFE/read-mostly; records local status and contacts endpoints.
swift run \
  --package-path "Client App/MCPummelchenModClient" \
  MCPummelchenModClient --once
```

### Sync helper

```sh
# OPERATOR for the selected client directories; use disposable dirs for development.
swift run \
  --package-path "Client App/MCPummelchenModClient" \
  pummelchen-client-sync sync \
  --force \
  --server-url "<server-url>" \
  --minecraft-dir "<disposable-minecraft-dir>" \
  --pummelchen-home "<disposable-pummelchen-home>" \
  --db "<disposable-client-duckdb>" \
  --client-id "<test-client-id>" \
  --no-report \
  --skip-java-repair
```

Optional flags:

- `--allow-while-running`
- `--no-client-api-token`

Do not use the real player's Minecraft directory for development tests without explicit consent/backups.

### Watch helper

```sh
# SAFE-ish with disposable client dirs and bounded cycles; may trigger sync.
swift run \
  --package-path "Client App/MCPummelchenModClient" \
  pummelchen-client-sync watch \
  --server-url "<server-url>" \
  --minecraft-dir "<disposable-minecraft-dir>" \
  --pummelchen-home "<disposable-pummelchen-home>" \
  --db "<disposable-client-duckdb>" \
  --client-id "<test-client-id>" \
  --max-cycles 1 \
  --after-event-id "<optional-event-id>" \
  --no-report \
  --skip-java-repair
```

## DuckDB commands

### Apply migrations

```sh
# DISPOSABLE example
DB="$(mktemp -d)/pummelchen-test.duckdb"

swift run \
  --package-path "Server App/MCPummelchenModServer" \
  pummelchen-duckdb migrate \
  --duckdb "$DB" \
  --migrations-dir "Server App/Database/duckdb/migrations"
```

Production migration is an **OPERATOR** action and should use an approved backup and exact runtime paths.

### Health

```sh
# SAFE/read-oriented against the selected DB; initialization behavior should be reviewed for a new DB.
swift run \
  --package-path "Server App/MCPummelchenModServer" \
  pummelchen-duckdb health \
  --duckdb "$DB"
```

### Export and verify Parquet

```sh
# DISPOSABLE output example
OUT="$(mktemp -d)/pummelchen-parquet"

swift run \
  --package-path "Server App/MCPummelchenModServer" \
  pummelchen-duckdb export-parquet \
  --duckdb "$DB" \
  --output-dir "$OUT"

swift run \
  --package-path "Server App/MCPummelchenModServer" \
  pummelchen-duckdb verify-parquet \
  --duckdb "$DB" \
  --input-dir "$OUT"
```

## systemd deployment commands

The tracked `Server App/systemd/README.md` instructs operators to copy units/drop-ins to `/etc/systemd/system/` and then run:

```sh
# OPERATOR/root on the target VPS
systemctl daemon-reload
```

Unit start/stop/enable commands are intentionally not prescribed here because the target and deployment procedure must be operator-confirmed.

## nginx validation/deployment

The repository documents the files and runtime layout but does not define a repository-local nginx lint script. Host-level `nginx -t` is a normal deployment check, but it was not found as a tracked project command; treat it as operator/environment validation rather than a repository guarantee.

## Format, lint, Docker, and CI

- No dedicated Swift formatter command was found.
- No dedicated lint command was found.
- No Dockerfile or compose workflow was found in the inspected paths.
- No GitHub Actions workflow was found.

Do not claim those checks ran. Build and tests are the available repository-level validation.

## Documentation/onboarding validation

From a checkout containing these files:

```sh
# SAFE
python -m json.tool .ai/MANIFEST.json >/dev/null

git diff --check

git status --short

find . -path './.git' -prune -o -type f -print \
  | grep -E '(CLAUDE\.md|\.github/copilot-instructions\.md|\.ai/(GPT-|CLAUDE|QWEN|GEMINI|GLM|DEEPSEEK|OTHER-AI))' \
  || true
```

Perform a secret scan using secure local tooling without embedding real credential values into the command output.

## Evidence

- `Server App/MCPummelchenModServer/Sources/MCPummelchenModServer/main.swift`
- `Client App/MCPummelchenModClient/Sources/MCPummelchenModClientSync/main.swift`
- `Server App/MCPummelchenModServer/Sources/PummelchenDuckDB/main.swift`
- `Server App/Database/duckdb/README.md`
- `Server App/systemd/README.md`
- all three `Package.swift` files
