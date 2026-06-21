# Pummelchen systemd

This directory contains tracked systemd drop-ins used by the live Debian VPS.

- `MCPummelchenModServer.service` is the live Swift server app service.
- `MCPummelchenModServer.service.d/minecraft-autostart.conf` makes the Swift server app start the live Minecraft server and keeps RCON firewalled to localhost.
- `MCPummelchenModServer.service.d/performance.conf` raises the open-file limit for the Swift server and its Minecraft child process.
- `MCPummelchenModUpdateScan.service` runs the all-supported mod update scan against every DuckDB `live` and `staging` Minecraft version. During staging-version scans, the Swift scanner seeds missing target-version candidates from the live baseline inventory before checking upstream URLs, so new Minecraft versions do not silently miss mods that are still waiting for compatibility validation.
- `MCPummelchenModUpdateScan.timer` runs that scan daily at 12:00 on the VPS. The live VPS timezone is UTC, so this is lunchtime UTC0.

Apply changes by copying the service and timer files to `/etc/systemd/system/`, copying drop-ins to `/etc/systemd/system/MCPummelchenModServer.service.d/`, and running `systemctl daemon-reload`.
