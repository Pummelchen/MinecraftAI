# Pummelchen systemd

This directory contains tracked systemd units and drop-ins used by the live Debian VPS.

- `MCPummelchenModServer_26.1.2.service` is the Swift server app for `/var/minecraftai/26.1.2`, bound to `127.0.0.1:8787`, and manages only `/var/minecraft_26.1.2`.
- `MCPummelchenModServer_26.2.service` is the Swift server app for `/var/minecraftai/26.2`, bound to `127.0.0.1:8788`, and manages only `/var/minecraft_26.2`.
- `MCPummelchenModServer_26.3.service` is the Swift server app for `/var/minecraftai/26.3`, bound to `127.0.0.1:8789`, and manages only `/var/minecraft_26.3`.
- `MCPummelchenModServer_26.1.2.service.d/minecraft-autostart.conf` makes the Swift server app start the live Minecraft server and keeps RCON firewalled to localhost.
- `MCPummelchenModServer_26.1.2.service.d/performance.conf` raises the open-file limit for the Swift server and its Minecraft child process.
- `MCPummelchenModUpdateScan.service` runs the 26.1.2-only mod update scan against the 26.1.2 DuckDB records. It stops `MCPummelchenModServer_26.1.2.service` before the write-heavy scan and starts it again afterward, which gives the scanner exclusive DuckDB write access while the Minecraft Java process stays alive through the server service `KillMode=process` boundary. The service also enables source-link discovery through Modrinth/CurseForge APIs, direct provider-site HTML searches, and Google result pages filtered to those two sites, capped at 2 discovery searches per second.
- `MCPummelchenModUpdateScan.timer` runs that scan daily at 12:00 on the VPS. The live VPS timezone is UTC, so this is lunchtime UTC0.

Each dedicated server app gets its own `runtime/data/pummelchen.duckdb`. A clean vanilla app database should keep only its single `core.minecraft_server_versions` row and no mod, shader, resource-pack, config, release, or client inventory rows.

Apply changes by copying the service and timer files to `/etc/systemd/system/`, copying any drop-ins to the matching `/etc/systemd/system/<service>.d/`, and running `systemctl daemon-reload`.
