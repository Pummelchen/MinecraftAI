# Implementation Plan

The build plan for the MinecraftAI mod engine: what gets built, in what order, and what "done" means for each phase.

This file is the **canonical phase list** and lives with the code on purpose. The phase that completes it updates it in the same commit. The reasoning behind each decision lives in the [wiki](https://github.com/Pummelchen/MinecraftAI/wiki); this file records what to build, in what order, and when it counts as done.

**Status:** Phase 0 is live. Phases 1–8 are not started.

## Fixed decisions

These are settled. Changing one means reopening the design, not editing this table.

| Area | Decision |
|---|---|
| Language | Swift 6.3.3, strict concurrency |
| Process model | One engine process for every Minecraft version and the website API |
| State | Local SQLite in WAL mode via GRDB — see [State Database](https://github.com/Pummelchen/MinecraftAI/wiki/State-Database) |
| Edge | Master Caddy owning 80/443 for the host, routing by hostname — **live** |
| Addressing | Hostname-only. `https://minecraft.91.99.176.243.nip.io`. Nothing on the host answers by bare IP |
| Input | Google Sheet, one tab per Minecraft version; the engine reads and writes it |
| Versions | Data in a table, never code — see [Adding a Version](https://github.com/Pummelchen/MinecraftAI/wiki/Adding-a-Version) |
| Resolution | Pin exact files and hashes; update only on explicit request |
| Validation | Boot plus idle soak in a throwaway session |
| Unit of validation | The modset digest — jars plus config overrides — never the individual mod |
| Deploys | Every change goes through a plan. Staging applies itself; the live version waits for approval. The live role is a column |
| Removals | Classified as potentially destructive and gated on a world-content check — see [Change Safety](https://github.com/Pummelchen/MinecraftAI/wiki/Change-Safety) |
| Players | An `.mrpack` per version. No client application |

## Target layout

```
engine/      Swift package: EngineCore library, pummelchen-engine CLI, tests
caddy/       master edge for the whole host (live)
site/        MinecraftAI's own web server and web root (live, placeholder)
PLAN.md      this file
```

## Phase 0 — Edge ✅

**Delivered.** Master Caddy on 80/443 with automatic certificates and HTTP/3; hostname routing to each project's own web server; MinecraftAI's site server on `127.0.0.1:8801`; security headers on every site; nginx and epmd disabled; nothing reachable by bare IP.

**Exit criteria — met:**
- [x] `caddy/scripts/test-edge.sh` passes: routing, Host preservation, isolation
- [x] An external checker confirms QUIC and HTTP/3 for every hostname
- [x] TLS 1.3 with a complete chain on every hostname
- [x] No public listener beyond 22, 80, 443 and RoomCAD's `8443` alias

## Phase 1 — Spine: versions, store, resolution

The foundation. Useful on its own: it answers "which of these 300 mods have a build for this Minecraft version?" without anyone opening a browser tab.

**Deliverables**
- `engine/` Swift package; `pummelchen-engine` builds with `--static-swift-stdlib`
- GRDB schema through `DatabaseMigrator`: versions, mods, resolved files, provenance
- Content-addressed store at `/var/minecraftai/shared/store/<sha256>.jar`, materialised through hardlinks
- Sheet reader authenticated as a Google service account (RS256 JWT); read-only in this phase
- Modrinth resolver; CurseForge once an API key exists
- Commands: `version list`, `version add` (row only), `sync`, `resolve`

**Exit criteria**
- [ ] Migrations apply to a fresh database on every test run
- [ ] `resolve` reports, for every row of a tab, either a pinned file and SHA-256 or `unavailable` with a reason
- [ ] Running `resolve` twice changes nothing and downloads nothing
- [ ] A blob is written once per hash, and a corrupted blob is detected on read
- [ ] Re-resolving an **unchanged** version whose upstream bytes have changed keeps the pinned file and raises an alert — see [Supply Chain](https://github.com/Pummelchen/MinecraftAI/wiki/Supply-Chain)
- [ ] A test fails if a Minecraft version string appears anywhere in `engine/Sources`

## Phase 2 — Static analysis, modset digest, sheet write-back

The system can say "this set cannot work, and here is the line in the mod that says why" before any JVM starts.

**Deliverables**
- Reads `META-INF/neoforge.mods.toml` without extracting the jar
- Checks: missing required dependency, duplicate mod ID, Minecraft or NeoForge range mismatch, declared `incompatible`, the same mod present at two versions
- Records each mod's declared `side`, which Phase 7 needs
- Modset assembly and digest covering jars **and** config overrides
- Writes the system-owned columns back to the sheet, under protected ranges

**Exit criteria**
- [ ] One fixture per failure class, each rejected with the correct reason
- [ ] A digest is identical across runs and machines, and changing any byte of any member changes it
- [ ] Sheet write-back is idempotent and never touches a human-owned column

## Phase 3 — Plan, apply, deploy, rollback

After this phase the engine is a working mod manager. Everything later is about trust.

**Deliverables**
- A pure planner: `(desired, current) → plan`, classifying each change as `add`, `update` or `remove`
- A `level.dat` namespace check that flags a removal as destructive when the world knows the mod
- `apply`: materialise the set, verify a world backup before any destructive change, flip `current`, restart
- `rollback`, and a failed start that rolls back by itself and reports it
- Full version provisioning: NeoForge discovery from Maven, a generated systemd unit, sheet tab creation, carry-forward from a reference version
- The live gate, reading the live role from the version table

**Exit criteria**
- [ ] Planner unit tests cover every classification, with no network and no Minecraft server
- [ ] A destructive removal is refused without `--acknowledge-destructive` **and** a verified backup
- [ ] `apply` refuses a plan computed against a state that has since changed
- [ ] Deleting a sheet row reports an anomaly and removes nothing
- [ ] `version add` on a fresh version produces a ready server, or a specific list of what blocks it

## Phase 4 — Boot validation

**Deliverables**
- Throwaway sessions under `/var/minecraftai/test/<run-id>/`, launched with `systemd-run --scope`, resource limits and a raised `oom_score_adj`
- Readiness detection on `Done (…)! For help`, followed by an idle hold
- Failure classification: crash report, `FATAL`, mixin error, duplicate registration, mod-count mismatch, timeout
- Verdicts stored against digests; any digest whose verdict flips is marked `flaky`
- A concurrency cap for sessions (starting value 2)
- The **canary**: a scheduled run of a known-bad set that must fail

**Exit criteria**
- [ ] A known-good fixture set validates
- [ ] Every failure-class fixture is rejected with the right classification
- [ ] The canary fails, and a canary that passes raises an alert
- [ ] A session cannot write outside the test root — enforced by the path check, not assumed
- [ ] A runaway session is killed without affecting a running live server

The canary moved here from the feedback-loop phase. A validator should be checked from its first run, not after it has been trusted for months.

## Phase 5 — Conflict graph and bisection

The phase where running the system starts getting cheaper instead of more expensive.

**Deliverables**
- Conflict edges carrying evidence, scoped to mod versions and Minecraft version, marked stale when either side updates
- The proposer excludes known-bad pairs
- Delta bisection against the last known-good set, testing both branches of each split in parallel
- Deferred counterpart search, run only on request

**Exit criteria**
- [ ] Synthetic conflict fixtures are bisected to the right culprit
- [ ] A known-bad pair is never proposed again
- [ ] A bisection that cannot reproduce the original failure is discarded, not reported

## Phase 6 — Website

**Deliverables**
- API: `/api/v1/versions`, `/api/v1/versions/{version}/mods`, `/api/v1/ping` with `Server-Timing`
- Server status read over Server List Ping, not from the engine's own view
- Static site with the glass design recovered from `archive/v1`, a data-driven version selector and deployed mod lists
- Latency measured as the median of several samples with the first discarded, labelled as latency to the host
- A Content-Security-Policy, replacing the TODO in `site/Caddyfile`

**Exit criteria**
- [ ] A version added to the table appears on the site with no code change
- [ ] A hung server shows as down, even while its process is alive
- [ ] The site sends a CSP with no `unsafe-inline`

## Phase 7 — Client packs

**Deliverables**
- An `.mrpack` per version, generated from the deployed modset and filtered to `BOTH` and `CLIENT` sides
- Third-party mods referenced rather than embedded wherever provider terms require it
- The pack names its digest; it is served beside the site

**Exit criteria**
- [ ] A generated pack imports into a stock launcher and joins the server
- [ ] Server-only mods are absent from the pack
- [ ] Every hash in the index verifies

## Phase 8 — Feedback loops

**Deliverables**
- A crash-report watcher on each live server that attributes reports to mods and attaches them to the deployed digest
- Player reports that record the version and digest deployed at the time
- Optional: noticing newer upstream builds and suggesting them, never applying them

**Exit criteria**
- [ ] A crash fixture is attributed to the right mod
- [ ] Every report carries the digest that was live when it was filed

## Prerequisites

| Needed | Blocks | Status |
|---|---|---|
| Three sheet tabs populated, spreadsheet shared with the service account | Phase 1 | Open |
| Google service account and key on the VPS | Phase 1 | Open |
| Swift 6.3.3 build approach: on the VPS, or static build elsewhere | Phase 1 | Open |
| CurseForge API key | Phase 1, for CurseForge-hosted mods only | Open |
| Which version starts as live | Phase 3 | Open |
| DNSSEC-signed domain | Nothing — recommended | Open |

## Working rules

- **Anything the daemon does automatically can also be run by hand.** The loop calls the same code paths as `resolve`, `plan` and `validate`.
- **No Minecraft version in source, config, units, routes or the site** — enforced by a test from Phase 1 onward.
- **Migrations run from scratch in the test suite on every run.**
- **The planner stays pure:** no network, no side effects, no clock reads.
- **A phase counts as done when its exit criteria pass,** and this file is updated in the same commit, which is then pushed.
