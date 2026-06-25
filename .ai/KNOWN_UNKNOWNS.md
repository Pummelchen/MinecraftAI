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
# Known Unknowns and Conflicts

## Conflicts

| Area | Status | Details |
|---|---|---|
| Client/control API authentication | `conflicting`, `needs_human_review` | Recent code removed required client API auth, but `Server App/Docs/contracts/CLIENT_IDENTITY.md` still describes authenticated write/report and polling traffic. Current source should win, but security changes need human review. |
| Swift version | `conflicting` | Package manifests declare Swift tools `6.2`; DuckDB README mentions a Swift `6.3.2` host. Use a compatible local toolchain and verify deployment expectations. |

## Unknowns

- No CI workflow file was found by targeted checks.
- Live deployment state under the production runtime path is not available from repository files.
- Live DuckDB contents and external mod/provider state cannot be verified from source alone.
- Dedicated lint/format commands were not found.
- Release, DMG, and headless-live-soak commands require operator context and runtime artifacts.

## Model-specific file migration

No standard model-specific instruction files were found at checked paths. No migration, deprecation note, or deletion was performed.

## Ask a human before editing

Client identity/control/reporting security behavior, production DuckDB migrations, live data repair, nginx public routing/TLS/cache policy, systemd hardening, DMG private credential packaging, world reset/RCON workflows, and live-version promotion rules.
