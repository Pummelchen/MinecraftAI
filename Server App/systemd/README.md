# Pummelchen systemd

This directory contains tracked systemd drop-ins used by the live Debian VPS.

- `pummelchen-swift-server.service.d/performance.conf` raises the open-file limit for the Swift server and its Minecraft child process.

The drop-in is applied by copying it to `/etc/systemd/system/pummelchen-swift-server.service.d/` and running `systemctl daemon-reload`. The new limit takes effect on the next `pummelchen-swift-server` restart.
