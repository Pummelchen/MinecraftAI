# Pummelchen systemd

This directory contains tracked systemd drop-ins used by the live Debian VPS.

- `MCPummelchenModServer_26.1.2.service` is the live Swift server app service.
- `MCPummelchenModServer_26.1.2.service.d/minecraft-autostart.conf` makes the Swift server app start the live Minecraft server and keeps RCON firewalled to localhost.
- `MCPummelchenModServer_26.1.2.service.d/performance.conf` raises the open-file limit for the Swift server and its Minecraft child process.
- `MCPummelchenModUpdateScan.service` runs the 26.1.2-only mod update scan against the 26.1.2 DuckDB records. It stops `MCPummelchenModServer_26.1.2.service` before the write-heavy scan and starts it again afterward, which gives the scanner exclusive DuckDB write access while the Minecraft Java process stays alive through the server service `KillMode=process` boundary. The service also enables source-link discovery through Modrinth/CurseForge APIs, direct provider-site HTML searches, and Google result pages filtered to those two sites, capped at 2 discovery searches per second.
- `MCPummelchenModUpdateScan.timer` runs that scan daily at 12:00 on the VPS. The live VPS timezone is UTC, so this is lunchtime UTC0.

When a new Minecraft server version is added to DuckDB, run `MCPummelchenModServer server-version-bootstrap --minecraft-version <target> --duckdb <file>` first. It previews the previous live-version mods that can be carried forward, skips banned/failed rows, preserves `Priority Mod` and `Admin Locked` as protected, and with `--dry-run false` copies working baseline files into the new server package before the normal scan/apply/release validation.

Apply changes by copying the service and timer files to `/etc/systemd/system/`, copying drop-ins to `/etc/systemd/system/MCPummelchenModServer_26.1.2.service.d/`, and running `systemctl daemon-reload`.
