<!--
AI onboarding file.
Mode: project-management-control-plane
Indexed commit: aa52bcab16cda5cfca5a8e146f4356842cc4bbcb
Last generated: 2026-07-09T05:25:00+02:00
Generator: GPT-5.5 Thinking
Purpose: Define GitHub PM workflow, Codex routing, human review queues, and release evidence handling.
Audience: Maintainers and high-capability AI coding agents working through GitHub Issues, Milestones, Projects, and PRs.
Human edits are allowed. Future refreshes should preserve valid human edits.
-->
# Project Management Control Plane

This document defines how MinecraftAI work should be routed through GitHub Issues, Milestones, and Projects so AI coding agents can safely pick up focused tasks while human operators retain authority over production-sensitive decisions.

Use this document together with `AI_INDEX.md`, `AGENTS.md`, `.ai/START_HERE.md`, `.ai/COMMANDS.md`, `.ai/TESTING.md`, `.ai/SECURITY.md`, and `.ai/KNOWN_UNKNOWNS.md`. Do not duplicate or replace those onboarding files here; this file only covers project-management rules.

## Operating model

- GitHub Issues are the task unit: features, bugs, docs, tests, CI, operations, research, and release-evidence work.
- GitHub Milestones are phase/release buckets, not individual tasks.
- GitHub Projects provide board state, roadmap phase, priority, owner, risk, area, Codex suitability, and human-review queues.
- Pull requests should close or advance exactly one focused issue unless the issue explicitly authorizes a grouped documentation-only change.
- AI agents must update progress through issue comments, PR descriptions, validation notes, and linked PR activity.

## Milestones

Use these milestones unless a future human-approved roadmap replaces them:

| Milestone | Purpose |
|---|---|
| `M0 - Project Control Plane` | GitHub metadata, project board, issue hygiene, templates, PM documentation. |
| `M1 - AI Onboarding and Repo Navigation` | `AI_INDEX.md`, `AGENTS.md`, `.ai/*`, repo maps, commands, safety docs. |
| `M2 - Mod Discovery and Dependency Resolution` | Source discovery, dependency resolution, provider metadata, dry-run reporting. |
| `M3 - Compatibility Checks and Smoke Testing` | Compatibility diagnostics, smoke checks, rejection reasons, local validation. |
| `M4 - Release Build and Immutable Artifacts` | Release assembly, manifests, checksums, ZIP/MRPACK/DMG artifacts, validation. |
| `M5 - Multi-Version Live/Staging Management` | Live/staging version rows, version-scoped aliases, promotion safety, auditability. |
| `M6 - macOS Client Sync and Self-Update` | Client status, sync, repair, defaults, Java/NeoForge, DMG self-update. |
| `M7 - DuckDB Schema, Audit, and Reporting` | Migrations, health checks, reporting views, audit rows, disposable validation. |
| `M8 - Public Website, nginx, and Downloads` | Website consumers, public edge, cache/download behavior, status visibility. |
| `M9 - systemd, Server Supervision, and Operations` | Service units, timers, supervisor, RCON boundary, operational docs. |
| `M10 - CI, Test Automation, and Release Evidence` | GitHub Actions, test automation, evidence inventories, acceptance artifacts. |
| `M11 - Production Readiness and Human Approval Gates` | Security, release approvals, destructive-operation gates, policy decisions. |

## Label taxonomy

### AI routing

- `ai:ready`
- `ai:needs-context`
- `ai:blocked`
- `ai:human-review`
- `ai:codex-small-pr`
- `ai:codex-large-task`
- `ai:do-not-autocode`

### Type

- `type:feature`
- `type:bug`
- `type:refactor`
- `type:test`
- `type:docs`
- `type:ci`
- `type:ops`
- `type:security`
- `type:research`
- `type:release`
- `type:database`

### Priority

- `priority:p0`
- `priority:p1`
- `priority:p2`
- `priority:p3`

### Risk

- `risk:low`
- `risk:medium`
- `risk:high`
- `risk:critical`
- `risk:security`
- `risk:data-loss`
- `risk:production`
- `risk:destructive`
- `risk:client-update`
- `risk:release-activation`

### Area

- `area:ai-onboarding`
- `area:server`
- `area:client`
- `area:shared-contracts`
- `area:duckdb`
- `area:mod-discovery`
- `area:mod-compatibility`
- `area:release-build`
- `area:headless-soak`
- `area:multi-version`
- `area:website`
- `area:nginx`
- `area:systemd`
- `area:rcon`
- `area:world-management`
- `area:security`
- `area:ci`
- `area:docs`

### Blockers and evidence

- `blocked:external`
- `blocked:needs-decision`
- `blocked:needs-evidence`
- `blocked:needs-credentials`
- `blocked:needs-production-access`
- `blocked:needs-live-test`
- `evidence:required`
- `evidence:provided`
- `release-gate`

## GitHub Project fields

Recommended project name: `MinecraftAI Project`.

| Field | Values |
|---|---|
| Status | Backlog; Ready for AI; In Progress; PR Open; Review; Blocked; Human Decision Needed; Done |
| Phase | M0 Project Control Plane; M1 AI Onboarding and Repo Navigation; M2 Mod Discovery and Dependency Resolution; M3 Compatibility Checks and Smoke Testing; M4 Release Build and Immutable Artifacts; M5 Multi-Version Live/Staging Management; M6 macOS Client Sync and Self-Update; M7 DuckDB Schema, Audit, and Reporting; M8 Public Website, nginx, and Downloads; M9 systemd, Server Supervision, and Operations; M10 CI, Test Automation, and Release Evidence; M11 Production Readiness and Human Approval Gates |
| Priority | P0; P1; P2; P3 |
| Owner | Codex; Human; Mixed; External |
| Risk | Low; Medium; High; Critical |
| Area | AI Onboarding; Server; Client; Shared Contracts; DuckDB; Mod Discovery; Mod Compatibility; Release Build; Headless Soak; Multi-Version; Website; nginx; systemd; RCON; World Management; Security; CI; Docs |
| Human Review Required | Yes; No |
| Evidence Required | Yes; No |
| Codex Suitability | Safe for Codex; Needs Human Context; Do Not Autocode |

Recommended views:

- Board by Status
- Roadmap by Phase
- Codex Ready Queue
- Human Review Queue
- Blocked Items
- Release Gate Evidence
- Production Risk Queue
- Database and Migration Queue
- Client Update Queue
- Website and Public Edge Queue

## Priority rules

| Priority | Use for |
|---|---|
| P0 | Security bugs, release-integrity failures, data-loss risk, broken client update path, live/staging confusion, destructive production risk. |
| P1 | Release-gate gaps, failing core tests, mod pipeline reliability, CI/test automation needed for safe AI work. |
| P2 | Observability, reporting, website accuracy, docs drift, non-critical UX improvements. |
| P3 | Cleanup, refactors, nice-to-have docs, developer ergonomics. |

## Codex suitability rules

Mark `Safe for Codex` only when all are true:

- Acceptance criteria are clear and verifiable.
- Relevant files/directories are listed.
- Safe validation commands are listed.
- No production secrets, production access, destructive operations, release activation, live-version promotion, or deployed migration rewrite is required.
- The work can be completed as a focused PR.

Mark `Needs Human Context` when behavior depends on operator preference, docs/code conflict resolution, deployment ownership, nginx/systemd/auth policy, control APIs, live/staging policy, or migration intent.

Mark `Do Not Autocode` when the issue touches production credentials, destructive operations, world reset execution, release activation, live promotion, RCON operations, production DB mutation, or any operation that can alter live service state.

## Codex-ready workflow

1. Human or PM triages an issue with milestone, labels, project fields, acceptance criteria, validation, and risk.
2. Codex only starts work from `Status = Ready for AI`, `Codex Suitability = Safe for Codex`, and no `ai:blocked`, `ai:needs-context`, `ai:human-review`, or `ai:do-not-autocode` label.
3. Before coding, Codex reads `AI_INDEX.md`, `AGENTS.md`, `.ai/START_HERE.md`, task-relevant `.ai/*` files, and the current source files named in the issue.
4. Codex implements the smallest coherent change, opens a focused PR, and links the issue.
5. The PR body must state changed files, behavior/contract impact, commands actually run, commands skipped with reasons, evidence produced, and remaining risks.
6. The issue moves to `PR Open`, then `Review`, then `Done` after review and merge.

## Human review workflow

Apply `ai:human-review` and route to `Human Decision Needed` when an issue touches or decides any of the following:

- authentication or authorization;
- client identity, token enrollment, rotation, revocation, or credential storage;
- release activation, live-version promotion, stable aliases, or production release approval;
- production DuckDB migration, repair, backup, restore, or live data mutation;
- world reset execution, backup deletion, or destructive filesystem operations;
- RCON, firewall, watchdog, Minecraft process supervision, systemd service behavior, or nginx public routing/cache/security changes;
- executable download/update validation, checksum/signature/DMG/headless-soak gates;
- secrets, private runtime files, certificates, production environment files, or live client/user data.

For these issues, Codex may prepare research, diagrams, tests, or docs-only decision records when explicitly scoped, but it must not change live behavior or deploy code without human approval.

## Issue body expectations

Every issue should include:

- Objective
- Scope
- Non-goals
- Acceptance criteria with checkboxes
- Relevant files/directories
- Validation commands, smallest safe commands first
- Risk
- Human review requirement with reason
- Codex instructions
- Expected PR size
- Project fields

## Release and evidence workflow

Release-gate issues must distinguish local evidence from operator evidence.

Local evidence may include:

- Swift package builds and tests;
- shared contract tests;
- disposable DuckDB migration/health/export/verify runs;
- static website/API consumer review;
- local release validation against fixtures.

Operator evidence may include:

- production host `nginx -t` and deployed config comparison;
- systemd service/timer status and hardening checks;
- production DuckDB migration/backup/restore evidence;
- exact DMG hash, checksum, and headless live soak report;
- live Minecraft login/soak proof;
- release activation approval and post-activation health.

Never fabricate or imply evidence. If a command was not run, state that it was skipped and why.

## Safety reminders for PM triage

- Prefer dry-run mode for mod add, mod scan, apply, version bootstrap, world reset, migration, and release operations.
- Never use production paths, `Live Backup/`, a real player Minecraft directory, `/etc/systemd`, or live nginx paths for routine development validation.
- Do not rewrite deployed DuckDB migrations without explicit human approval.
- Do not bypass release validation, checksum validation, DMG validation, smoke tests, or headless soak validation.
- Do not commit secrets, tokens, RCON passwords, private keys, certificates, production environment files, or live client/user data.
- Production duties remain in Swift, DuckDB, nginx, and systemd unless a human-approved architecture decision changes that boundary.
