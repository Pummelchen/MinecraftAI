<img width="1055" height="1491" alt="When a new mod version is detected workflow" src="Server%20App/Docs/assets/readme-mod-update-workflow.png" />

Web Monitor of the Live Minecraft Server

<img width="1336" height="1723" alt="image" src="https://github.com/user-attachments/assets/05f64b08-ea67-4c79-a5b2-9d5efd1d69ef" />



# Minecraft AI Server/Client Mod Updater

An AI-assisted system for automatically managing Minecraft server and clients with 300+ mods.

This project uses OpenAI Codex as a natural-language interface for mod management. Instead of manually downloading and validating mods, you can issue instructions such as:

"Add mod Biomes O' Plenty"

The Minecraft runtime starts from a vanilla server and layers the managed mod pack onto it through NeoForge. The same release flow also supports client-side shader packs, resource packs, and client configuration scripts so the server and macOS clients stay aligned within seconds.

The Swift server app is the live service owner: it exposes the server API, feeds nginx with live status data, and starts the Minecraft NeoForge runtime from the managed server directory.

The system then performs the full update pipeline automatically:

- Mod discovery — Searches major Minecraft mod repositories and sources.
- Download & integration — Retrieves the requested mod and prepares it for deployment.
- Compatibility validation — Runs automated checks against an existing 300+ mod environment to detect conflicts or breaking changes.
- Automated testing — Executes validation chains, including headless Minecraft client tests, to verify stability and compatibility.
- Live deployment — Once all tests pass, the mod is distributed automatically to the Minecraft server and all connected clients.

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
