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
# Security Notes for AI Agents

## High-risk assets

Do not commit or log private runtime values, client identity material, authorization headers, RCON passwords, environment-file contents, private app resources, or production database contents.

## Verified security boundaries

- nginx terminates public HTTPS and proxies `/api/` to a local Swift server.
- The tracked systemd server service includes hardening settings and constrained write paths.
- API proxy body size is limited in nginx config.
- Public downloads and operational JSON have distinct cache/header behavior.
- Client sync verifies size/SHA256 and uses temporary paths before final replacement.

## Authentication conflict

Recent code removed hard client API auth requirements. Older identity docs still describe authenticated write/report and polling traffic. Treat current source as the source of truth, but ask for human security direction before changing this area.

## AI safety rules

Use placeholders in examples. Do not add static JSON fallbacks for live operational website data. Do not weaken nginx/systemd hardening without explicit direction. Do not run production migrations, release activation, world reset, RCON, or deployment commands unless explicitly requested. Use disposable databases for development examples.

## Evidence

- `Server App/Docs/contracts/CLIENT_IDENTITY.md`
- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md`
- client control/sync source files
- nginx and systemd config files
