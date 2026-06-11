Minecraft 26.1.2 Client Package for macOS Apple Silicon

Target client: macOS on Apple Silicon (M2/M3), official Minecraft launcher.
Target loader: NeoForge 26.1.2.71.
Target server: 91.99.176.243:25565.
Package contents: 285 mod jars, 9 resource packs, 1 shader pack, and updater tooling scripts.
Generated: 2026-06-04.

Recommended install:
1. Download and open Pummelchen-Client-Installer.dmg from the status page.
2. Run Pummelchen Installer.app.
3. Wait for the final "Ready to play Pummelchen Server" message.
4. The installer opens Minecraft Launcher. Select the NeoForge 26.1.2 profile and join Pummelchen Server.

What the installer does:
- Downloads and verifies the current client package.
- Installs or updates a user-local Temurin Java 25 Apple Silicon runtime.
- Syncs the tested mods, resource packs, shader packs, and updater tooling scripts into the vanilla launcher folder.
- Moves unmanaged mod jars aside before installing the tested Pummelchen set.
- Installs the NeoForge client profile.
- Adds the Pummelchen Server entry to servers.dat.
- Installs the Pummelchen background updater as a user LaunchAgent.
- Installs Pummelchen Client Doctor for crash-log collection and upload.
- Verifies installed file hashes before reporting ready.

Automatic updates:
- The background updater checks the VPS sync manifest at login and every 1 minute.
- The server can also force a fast-track update by returning a fast window so clients
  poll every 120 seconds when an update is required.
- The background updater downloads only missing or changed mod, resource-pack,
  shader-pack, and tooling files.
- The manual terminal updater is installed as:
  ~/Library/Application Support/Pummelchen/bin/pummelchen-updater.sh
  It delegates to the same maintained updater used by the LaunchAgent:
  ~/Library/Application Support/Pummelchen/bin/pummelchen-auto-update.sh
- If updater scripts are damaged or stuck, the status page has a one-line curl
  repair command that redownloads both scripts from the VPS, makes them
  executable, and runs a forced sync.
- The updater reports current/target release status on each run so the server can track client update state.
- Each downloaded file is SHA256-verified before it replaces the local copy.
- Stale managed files are removed, and unmanaged managed files are moved aside to keep the client in sync with the server.
- Manual pre-launch sync is available at:
  ~/Applications/Pummelchen Minecraft.command
- Manual diagnostic upload is available at:
  ~/Applications/Pummelchen Send Logs.command
- If a new Minecraft crash report appears, the background updater uploads a
  redacted diagnostic bundle automatically.
- During staged server deploys, clients are instructed to update as soon as possible
  and the server broadcasts an in-game warning when a hotfix/quickfix window is active.
- Logs and status are written under:
  ~/Library/Logs/Pummelchen
  ~/Library/Application Support/minecraft/.pummelchen

Notes:
- This package is generated from the SQLite tracker in /var/minecraft_mods, not from Google Sheets.
- AutoFishing is included as autofishing-1.0.1.jar.
- Core client entries are included: Sodium, Iris, BSL Classic, ModernArch, and Dramatic Skys.
- BSL Classic is installed as a shader pack for Iris. Its latest stable CurseForge file is tagged for 1.21.9/Iris, not 26.1.x, so SQLite records it as a client-side compatibility override.
- Failed server candidates are not included in the client package unless separately marked client-only in SQLite.
- Final server validation reached Done. Remaining ERROR-tagged content/model/version-check lines are nonfatal and covered by the tracker baseline filter.
- The full file list and SHA256 hashes are in manifest.txt.

The installer targets the vanilla launcher folder:
~/Library/Application Support/minecraft

Advanced use:
The bundled Install Mods.command script is the inner installer used by the DMG.
It can also be run from Terminal for diagnostics. The updater payload is
tools/pummelchen-auto-update.sh and supports --check-only for a safe manifest
read test. The diagnostic collector is tools/pummelchen-client-doctor.sh.
