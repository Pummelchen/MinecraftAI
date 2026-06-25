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
# Playbooks

## Change a server API endpoint

Inspect `MCPummelchenModServerCore.response(for:)`, update server core route/payload code, add or update server tests, and update nginx aliases or contracts if public behavior changes.

## Change client sync/default behavior

Inspect `ClientSyncEngine.swift`, defaults writer/inspector files, and `ClientStatusService.swift`. Preserve first-install versus repeat-sync behavior. Keep SHA256/size verification and atomic replacement. Add or update client tests.

## Add a DuckDB migration

Inspect the DuckDB README and latest numbered migration. Create the next numbered migration. Do not edit deployed migrations unless a human confirms they are not deployed. Run migration and health against a disposable database.

## Change server CLI behavior

Update usage and argument parsing in server `main.swift`. Keep implementation in server core where possible. Prefer dry-run support for workflows that mutate files or database state. Add tests and update `.ai/COMMANDS.md`.

## Change nginx/systemd

Read nginx/systemd docs and `.ai/SECURITY.md`. Preserve local Swift proxy assumptions, generated download separation, no-store behavior for operational JSON, and service hardening unless explicitly directed.

## Refresh AI onboarding docs

Read `.ai/MANIFEST.json`, compare previous indexed commit to current HEAD if possible, update stale sections, preserve valid human edits, validate manifest JSON, check relative links, and update `.ai/CHANGELOG.md`.
