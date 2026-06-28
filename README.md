> **AI agents: start here**
>
> Before making changes, read [`AI_INDEX.md`](./AI_INDEX.md), then [`AGENTS.md`](./AGENTS.md).
> The generic first-session prompt is in [`.ai/START_HERE.md`](./.ai/START_HERE.md).
>
> These files summarize the repository architecture, commands, conventions, risks, and recommended reading order for a fresh AI session.
> They are vendor-neutral and intended for any high-end AI coding agent.

<img width="1055" height="1491" alt="When a new mod version is detected workflow" src="Server%20App/Docs/assets/readme-mod-update-workflow.png" />

Web Monitor of the Live Minecraft Server

<img width="1360" height="1646" alt="image" src="https://github.com/user-attachments/assets/6396c290-6f26-4cee-8e6a-996cd6bd9b54" />




# Minecraft Automatic Server/Client Mod Updater

An AI-assisted system for automatically managing Minecraft server and clients with 300+ mods.

This project uses AI environments like OpenCode/Codex/Qoder as a natural-language interface for mod management. Instead of manually downloading and validating mods, you can issue instructions such as:

"Add mod Biomes O' Plenty"

The Minecraft runtime starts with a vanilla server and adds the managed mod pack through NeoForge. The same release flow also handles client-side shader packs, resource packs, and configuration files, keeping the server and macOS clients aligned through nginx-served HTTPS release downloads plus authenticated HTTPS live update control APIs.

`add-mod` is now a full pipeline command: when you call `MCPummelchenModServer add-mod` without `--dry-run true`, it resolves dependencies, applies compatibility checks, runs a server smoke test, builds a full release, runs the MC-version-scoped DMG build + 1-minute headless live soak, and publishes a DMG-backed release for download. Each generated macOS app is dedicated to one Minecraft server version and carries that version in the app name, such as `MCPummelchenModClient_26.2.app`.

The platform supports multiple Minecraft server versions side by side. The oldest supported version remains the live play target until newer versions pass validation. DuckDB stores supported server versions, NeoForge installer requirements, mod sources, scan results, release metadata, and client inventory with Minecraft/NeoForge version fields. The macOS client fetches the supported version list from the server API and keeps only a safe bundled fallback for bootstrap/offline use. It then installs supported NeoForge client profiles and Multiplayer entries named by version, for example `Pummelchen Server 26.1.2` and `Pummelchen Server 26.2`, so future Minecraft releases can be staged without disrupting the current live server.

The daily mod update check must scan every DuckDB-supported `live` and `staging` Minecraft version with `MCPummelchenModServer mod-update-scan --all-supported true`. It covers server mods, client mods, shaders, resource packs, configuration files, and rejected/failed mod candidates, then records scan status and test context in DuckDB for the website tables. The same scan can backfill redundant source links through Modrinth/CurseForge APIs, direct site HTML searches, and Google result pages limited to those two mod sites, capped at two discovery searches per second. Staging releases publish version-scoped current release files and versioned DMG aliases such as `/downloads/MCPummelchenModClient_26.2.dmg`, while only the DuckDB `is_live` version may update the global `/downloads/current-release.json` endpoint used by normal clients.


## Core Benefits For MC Server Admins

- Reduces manual mod management work by turning natural-language requests into repeatable update workflows.
- Lowers the risk of broken releases by testing new mods against the full existing mod stack before deployment.
- Keeps server and client mod sets aligned so players do not have to manually repair mismatched installations.
- Speeds up safe mod adoption by automating discovery, downloads, compatibility checks, and packaging.
- Provides a structured path for operating very large mod packs with hundreds of active mods.
- Preserves release state and database history so admins can audit what changed and when.
- Helps private servers move faster without depending on every player to understand mod loader internals.

## Platform Requirements

At present, the project supports the following environment:

- Minecraft Server: Debian 13 (Intel x86-64)
- Minecraft Clients: macOS 26 on Apple Silicon (M1-M5)

## Documentation

Additional setup details, architecture notes, and operational guidance are available in the [project wiki](https://github.com/Pummelchen/MinecraftAI/wiki).

The production database backup is stored in `Live Backup/` and is updated in-repo with each release as a point-in-time snapshot for recovery and audit.
