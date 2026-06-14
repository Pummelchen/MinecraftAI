# Pummelchen systemd

This directory contains tracked systemd drop-ins used by the live Debian VPS.

- `MCPummelchenModServer.service` is the live Swift server app service.
- `MCPummelchenModServer.service.d/minecraft-autostart.conf` makes the Swift server app start the live Minecraft server and keeps RCON firewalled to localhost.
- `MCPummelchenModServer.service.d/performance.conf` raises the open-file limit for the Swift server and its Minecraft child process.

Apply changes by copying the service file to `/etc/systemd/system/MCPummelchenModServer.service`, copying drop-ins to `/etc/systemd/system/MCPummelchenModServer.service.d/`, and running `systemctl daemon-reload`.
