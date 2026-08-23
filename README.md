# MinecraftAI

A mod release and conflict-validation system for three NeoForge Minecraft servers.

> **Status: design stage.** Nothing in this concept is implemented. The repository is intentionally near-empty while the architecture is settled. The previous implementation was retired — see [Archive](#the-retired-v1-system).

## The problem

Three Minecraft versions — 26.1, 26.2 and 26.3 — each run NeoForge with roughly 300 mods. Because mods do not all support every Minecraft version, each server carries a different collection.

That part is bookkeeping. The hard part is this: **mods that are individually compatible with a server version can still be incompatible with each other.** Two mods boot fine together until a third joins them; a mixin collides; two mods claim the same registry ID. Nothing in a mod's metadata reliably predicts it, so the only trustworthy answer comes from actually starting a server with that exact set of files and seeing whether it survives.

So no mod set reaches a live server until a throwaway session has proven it boots clean.

## Approach

**The mod set is the unit, not the mod.** A mod is never validated on its own — it is validated as part of a set. The list of exact files is hashed into a *modset digest* that behaves like a lockfile. Verdicts, deployments and rollbacks all attach to that digest, so there is no way to quietly change a file and keep a validation result.

**Bisect the change, not the set.** Booting 300 mods and learning that it crashed names no culprit. But the last validated set is already proven good, and you typically change six mods rather than three hundred — so delta-debugging just the change finds the offender in two or three rounds. Because the host runs several servers at once, both branches of each split are tested in parallel.

**Conflicts are remembered.** Every proven incompatibility becomes a permanent edge in a conflict graph and never costs another boot again. Combined with reading mod metadata straight out of the jars — which catches missing dependencies, duplicate mod IDs, and mods that explicitly declare each other incompatible — most conflicts eventually get caught before a JVM ever starts.

## Architecture

All three servers run continuously, each on its own port. Conflict tests are additional short-lived servers on scratch ports, created and destroyed per run.

| Component | Responsibility | Scope |
|---|---|---|
| Manager | Reconciles the sheet against reality: resolve, static-check, propose, validate, deploy, write back. Supervises its Minecraft server. | Per version |
| Test runner | Boots candidate sets in throwaway sessions, judges them, destroys the directories. | Shared |
| Mod store | Content-addressed jar storage. Server and test mod directories are hardlinks into it. | Shared |
| State database | Modsets, verdicts, conflict graph, deployment history. | Shared |
| Caddy | Public HTTPS, the website, and the read-only API behind it. | Shared |

Per-version state lives under `/var/minecraftai/26.1`, `26.2` and `26.3`. The store, state database and website are shared, because the same jar often serves two Minecraft versions and the conflict graph is most useful when it accumulates across all of them.

## Input and output

Desired mod lists come from a Google Sheet — one tab per Minecraft version, listing name, URL and intent. The sheet is an **input**, not the source of truth for what is deployed; when the two disagree the database wins and the sheet is corrected. Human-owned and system-owned columns are kept strictly separate so intent is never confused with observation. See [Sheet Contract](https://github.com/Pummelchen/MinecraftAI/wiki/Sheet-Contract).

The website lets a visitor pick a Minecraft version and see the mods actually loaded on it — name, category, and a link to the original mod page — along with which servers are up and their measured latency to the host.

## Documentation

The full design lives in the [wiki](https://github.com/Pummelchen/MinecraftAI/wiki):

- [Architecture](https://github.com/Pummelchen/MinecraftAI/wiki/Architecture) — components, operating model, filesystem layout
- [Modset Model](https://github.com/Pummelchen/MinecraftAI/wiki/Modset-Model) — digests, the content store, the conflict graph
- [Conflict Testing](https://github.com/Pummelchen/MinecraftAI/wiki/Conflict-Testing) — the detection tiers and the session lifecycle
- [Bisection](https://github.com/Pummelchen/MinecraftAI/wiki/Bisection) — fault localization and its cost model
- [Sheet Contract](https://github.com/Pummelchen/MinecraftAI/wiki/Sheet-Contract) — column ownership rules
- [Website](https://github.com/Pummelchen/MinecraftAI/wiki/Website) — pages, API, and what latency can honestly be measured
- [Deployment and Rollback](https://github.com/Pummelchen/MinecraftAI/wiki/Deployment-and-Rollback) — the live gate
- [Open Decisions](https://github.com/Pummelchen/MinecraftAI/wiki/Open-Decisions) — what is still undecided

## The retired v1 system

The previous implementation — three Swift packages, DuckDB, Caddy, per-version systemd units — was retired before this redesign. It is preserved in full:

```bash
git checkout v1-retired
```

Also available as the branch `archive/v1`. Its production contracts are worth reading as prior art on release immutability, manifest verification and world-reset safety. Its architecture is deliberately not carried forward. See [v1 Archive](https://github.com/Pummelchen/MinecraftAI/wiki/v1-Archive).
