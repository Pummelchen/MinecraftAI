<img width="1055" height="1491" alt="When a new mod version is detected workflow" src="Server%20App/Docs/assets/readme-mod-update-workflow.png" />

Web Monitor of the Live Minecraft Server

<img width="1336" height="1723" alt="image" src="https://github.com/user-attachments/assets/05f64b08-ea67-4c79-a5b2-9d5efd1d69ef" />



# Minecraft AI Server/Client Mod Updater

An AI-assisted system for automatically managing Minecraft server and clients with 300+ mods.

This project uses AI environments like OpenCode/Codex/Qoder as a natural-language interface for mod management. Instead of manually downloading and validating mods, you can issue instructions such as:

"Add mod Biomes O' Plenty"

The Minecraft runtime starts from a vanilla server and layers the managed mod pack onto it through NeoForge. The same release flow also supports client-side shader packs, resource packs, and client configuration scripts so the server and macOS clients stay aligned within seconds.


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
