<img width="1055" height="1491" alt="When a new mod version is detected workflow" src="Server%20App/Docs/assets/readme-mod-update-workflow.png" />

Web Monitor of the Live Minecraft Server

<img width="1336" height="1723" alt="image" src="https://github.com/user-attachments/assets/05f64b08-ea67-4c79-a5b2-9d5efd1d69ef" />



# Minecraft AI Server/Client Mod Updater

An AI-assisted system for automatically managing Minecraft server and clients with 300+ mods.

This project uses AI environments like OpenCode/Codex/Qoder as a natural-language interface for mod management. Instead of manually downloading and validating mods, you can issue instructions such as:

"Add mod Biomes O' Plenty"

The Minecraft runtime starts with a vanilla server and adds the managed mod pack through NeoForge. The same release flow also handles client-side shader packs, resource packs, and configuration scripts, keeping the server and macOS clients aligned through nginx-served HTTPS release downloads plus authenticated HTTPS live update control APIs.

The platform supports multiple Minecraft server versions side by side. The oldest supported version remains the live play target until newer versions pass validation. DuckDB stores supported server versions, mod sources, scan results, release metadata, and client inventory with Minecraft/NeoForge version fields. The macOS client installs supported NeoForge client profiles and Multiplayer entries named by version, for example `Pummelchen Server 26.1.2` and `Pummelchen Server 26.2`, so future Minecraft releases can be staged without disrupting the current live server.


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

Additional setup details, architecture notes, and operational guidance are available in the [project wiki](https://github.com/Pummelchen/Minecraft/wiki).
