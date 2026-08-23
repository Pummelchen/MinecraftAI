# MinecraftAI

This project is being redesigned. The previous implementation has been retired and is no longer developed on `main`.

## Status

`main` is intentionally a clean slate. A new concept is being designed from scratch, and no part of the retired architecture should be treated as a constraint on it.

## The retired implementation

Everything that previously lived here is preserved in full and remains checkoutable:

| Reference | What it is |
|---|---|
| `v1-retired` | Annotated tag at the final v1 commit (`47458eb`) |
| `archive/v1` | Branch pinned to the same commit, for browsing on GitHub |

```bash
git checkout v1-retired
```

Nothing was deleted from history. The retirement commit removes the files from `main` only; all 128 tracked files, the full commit history, the design contracts, and the tracked DuckDB snapshot are reachable from the tag and the archive branch.

### What v1 was

An AI-assisted release and operations platform for a large modded Minecraft environment across Debian servers and macOS clients. Three Swift 6.2 packages (server, client, shared), DuckDB as the sole database, Caddy as the public HTTPS edge, and systemd for per-version service isolation. It covered mod discovery and dependency resolution, compatibility scanning, immutable releases with checksum-verified manifests, macOS DMG builds with headless soak gating, client synchronization and self-update, and guarded server administration.

It was verified green at the retirement commit: `Scripts/test-all.sh` passed all four suites (shared, client, server — 47 tests, and 8 Caddy edge tests).

### Why it is worth reading before redesigning

v1 accumulated operational rules that were learned rather than designed, and those are cheaper to inherit than to rediscover. The most load-bearing ones live in:

- `Server App/Docs/contracts/PRODUCTION_CONTRACTS.md` — release immutability, client sync manifest format, DMG acceptance and live-soak gating, safe world-reset behavior, mod-scan throttling and provider rules.
- `Server App/Docs/contracts/CLIENT_IDENTITY.md` — per-client identity, token storage, transport authentication, and rotation.

Read them as a record of hard-won constraints, not as a specification the new concept must satisfy.

### Known issues in v1, for the record

These were identified during the review that preceded retirement and are documented so the redesign does not reintroduce them:

- `CLIENT_IDENTITY.md` declared "no unauthenticated client write APIs" as a non-goal, but `POST /api/v1/control/events` and `POST /api/v1/control/acks` validated only the payload and client ID, with no bearer check — while every `/api/v1/clients/*` handler did enforce one.
- Documentation referred to `/opt/pummelchen-swift/runtime`, while the shipped systemd units used `/var/minecraftai/<version>/runtime`.
- `Server App/Database/duckdb/schema.sql` referenced `database/duckdb/migrations/...`, a path that did not resolve from the repository root.
- A single 2717-line file held the router and all 24 API handlers.
- There was no CI; the test suite existed and passed but nothing ran it automatically.

## Next

The new architecture is not yet defined. Design work starts from the problem, not from the retired code.
