<!--
AI onboarding file.
Mode: bootstrap
Indexed commit: 743356f85b0d4343cb8b1f71a92731eaf479bf47
Last generated: 2026-06-25T22:00:00+07:00
Generator: generic high-end AI coding agent
Purpose: Help future AI sessions understand this repository quickly.
Audience: Any high-capability AI coding agent, regardless of vendor or model family.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# Architecture

## Runtime shape

macOS client app and sync helper talk over HTTPS to nginx. nginx serves the public website and downloads and proxies API traffic to the local Swift server on `127.0.0.1:8787`. The Swift server reads/writes DuckDB and release/download files and coordinates Minecraft operational workflows.

## Server

`MCPummelchenModServer` is both an operator CLI and local HTTP server. The server core handles status, current release metadata, client health, live site data, Minecraft versions, mod inventory, failed mods, release history, update activity, control events, client reports, diagnostics, defaults events, and release manifests.

## Client

The macOS app displays sync status, endpoint health, defaults health, and update controls. The sync helper implements `sync` and `watch`. Client sync fetches current-release metadata, validates a TSV manifest, verifies size/SHA256, installs changed files atomically, writes local state, and can evaluate self-update metadata.

## Database and deployment

DuckDB is the canonical database. Migrations live in `Server App/Database/duckdb/migrations/`. nginx and systemd configs define the production edge and process boundaries.

## Trust boundaries

Public downloads must not contain private runtime values. DuckDB schema/data changes need migration discipline. systemd root service, RCON, world reset, and release activation require human caution.

## Evidence

- server and client entrypoints
- DuckDB README and migrations
- nginx README and site config
- systemd README and service files
- production contracts
