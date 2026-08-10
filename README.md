# MinecraftAI

MinecraftAI is an AI-assisted release and operations platform for managing a large modded Minecraft environment across Debian servers and macOS clients. It combines mod discovery, dependency resolution, compatibility checks, Minecraft smoke tests, immutable release builds, client synchronization, operational reporting, and guarded server administration.

The system is designed for mod packs with hundreds of managed files. Natural-language development tools can initiate work, but production changes remain controlled by explicit validation and operator approval.

<img width="1055" height="1491" alt="MinecraftAI mod update discovery, validation, release, and deployment workflow" src="Server%20App/Docs/assets/readme-mod-update-workflow.png" />

## What the project manages

- Server and client mods, shaders, resource packs, and configuration files.
- Mod provider discovery, dependency resolution, compatibility diagnostics, and rejected-candidate reporting.
- Server smoke tests and macOS DMG-backed headless client soak tests.
- Immutable releases with manifests, checksums, metadata, and DuckDB audit records.
- Multiple Minecraft versions with isolated runtime, database, API, and service boundaries.
- macOS client installation, repair, Java and NeoForge setup, inventory reporting, and verified self-update.
- Caddy-served HTTPS website, versioned APIs, and static release downloads.
- systemd-managed Swift services, Minecraft supervision, scheduled scanning, and operational logging.

## Architecture

| Component | Responsibility |
|---|---|
| `MCPummelchenModServer` | Operator CLI, local HTTP API, mod pipelines, release orchestration, Minecraft supervision, and guarded world operations. |
| `MCPummelchenModClient` | macOS status UI, synchronization, repair, managed Java and NeoForge, local inventory, and self-update. |
| `MCPummelchenModShared` | Shared API models, release and manifest validation, safe paths, hashing, defaults, and embedded DuckDB access. |
| DuckDB | Version, mod, scan, release, client, control, world, reporting, and audit state. |
| Caddy | Public HTTPS, versioned reverse proxying, website delivery, static downloads, cache policy, and access logging. |
| systemd | Version-specific service isolation, hardening, Minecraft process boundaries, and scheduled operations. |

Tracked deployment configuration defines these isolated service boundaries:

| Minecraft version | Swift API | Minecraft endpoint |
|---|---|---|
| 26.1.2 | `127.0.0.1:8787` | `91.99.176.243:25565` |
| 26.2 | `127.0.0.1:8788` | `91.99.176.243:25566` |
| 26.3 | `127.0.0.1:8789` | `91.99.176.243:25567` |

The repository defines desired deployment state. The live version, active release, deployed binaries, and production DuckDB contents must be verified from the operator environment rather than inferred from Git.

## Release workflow

`MCPummelchenModServer add-mod` can run the complete managed pipeline: resolve a candidate and its dependencies, apply compatibility checks, run a server smoke test, build a release, build the version-scoped macOS client DMG, require headless soak evidence, and publish release artifacts. Dry-run mode should be used first when investigating candidates or configuration.

Release directories are immutable. Only the Minecraft version marked live in DuckDB may publish global current-release aliases; staging versions use version-scoped metadata and download aliases. Clients verify manifest paths, file sizes, and SHA-256 values before replacing managed files.

The tracked `MCPummelchenModUpdateScan.service` performs a daily, exclusive 26.1.2 scan. The CLI also supports intentional all-supported scans for a suitable multi-version project root; dedicated version services require an explicit Minecraft version.

## API security status

Caddy exposes the public HTTPS edge while Swift services remain bound to loopback. Client registration, heartbeat, sync, inventory, diagnostics, and defaults-report endpoints require the configured bearer token. Control-event creation, polling, and acknowledgement currently validate payloads and client identifiers but do not enforce the same bearer guard. Minecraft server start/stop requests use a separate server-control password. This asymmetry is documented as an open security decision and must not be changed without reviewing client compatibility and deployment policy.

Large artifacts are always served as static Caddy downloads. Control-event payloads must not contain download URLs or downloadable file references.

## Development requirements

- Swift tools version 6.2 or a compatible newer toolchain.
- Native DuckDB available to the linker.
- Caddy for the public-edge integration tests.
- macOS 26 on Apple Silicon for the client GUI, DMG build, signing, and headless client acceptance workflow.
- Debian 13 x86-64 for the production server runtime.

Package paths contain spaces and must be quoted in shell commands.

```bash
swift build --package-path "Server App/MCPummelchenModShared"
swift build --package-path "Client App/MCPummelchenModClient"
swift build --package-path "Server App/MCPummelchenModServer"
Scripts/test-all.sh
```

`Scripts/test-all.sh` runs all three Swift package test suites and the isolated Caddy edge integration suite. It requires both DuckDB and Caddy to be installed.

## Production safety

Release activation, live-version promotion, production database changes, world reset, RCON, service deployment, secrets, and client update control require explicit operator approval. Prefer dry-run or disposable state where supported. Never bypass checksum, manifest, DMG, smoke-test, or headless-soak validation.

`Live Backup/` contains a tracked point-in-time DuckDB snapshot for recovery and audit. It is sensitive operational data and must not be assumed to match the current production database.

## Documentation

The [MinecraftAI Wiki](https://github.com/Pummelchen/MinecraftAI/wiki) contains the complete human-readable project guide:

- Architecture and component ownership.
- Repository navigation and development standards.
- Verified command and testing references.
- API, client, DuckDB, Caddy, systemd, deployment, and operations guides.
- Security boundaries, known limitations, release evidence, and human approval rules.

Current source, package configuration, tracked deployment configuration, canonical DuckDB migrations, and tests take precedence if documentation and implementation disagree.

## Server monitor

![MinecraftAI live server monitor](https://github.com/user-attachments/assets/6396c290-6f26-4cee-8e6a-996cd6bd9b54)
