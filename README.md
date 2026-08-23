# MinecraftAI

A mod release and conflict-validation system for three NeoForge Minecraft servers running on a single VPS.

> **Status: design stage.** Nothing in this concept is implemented. The repository is intentionally near-empty while the architecture is settled. The previous implementation was retired — see [Archive](#the-retired-v1-system).

## The problem

Three Minecraft versions — 26.1, 26.2 and 26.3 — each run NeoForge with roughly 300 mods. Because mods do not all support every Minecraft version, each server carries a different collection.

That part is bookkeeping. The hard part is this: **mods that are individually compatible with a server version can still be incompatible with each other.** Two mods boot fine together until a third joins them. Nothing in a mod's metadata reliably predicts it, so the only trustworthy answer comes from actually starting a server with that exact set of files and seeing whether it survives.

So no mod set reaches a live server until a throwaway session has proven it boots clean.

## The constraint that shapes the design

The VPS has 16 GB of RAM. A 300-mod NeoForge server needs roughly 8 GB of heap plus about 1 GB of Metaspace — hundreds of mods means tens of thousands of loaded classes — which is around **10 GB resident per server**.

Three of those is ~30 GB. It does not fit, and shrinking the heaps to force a fit is worse than not fitting: a mod set that size on a small heap lives in continuous garbage collection, and the resulting stutter and timeouts are indistinguishable from a mod conflict. That would corrupt the exact signal this system exists to produce.

The design therefore treats memory as **one schedulable slot** rather than pretending three servers can coexist. See [Memory Budget](https://github.com/Pummelchen/MinecraftAI/wiki/Memory-Budget).

## Approach

**One resident server.** A small TCP proxy holds all three Minecraft ports permanently, so all three servers appear in the multiplayer list while consuming nothing. A player connecting wakes the one they want; it stops again after fifteen idle minutes. The conflict tester is just another consumer queuing for the same slot.

**The mod set is the unit, not the mod.** A mod is never validated on its own — it is validated as part of a set. The list of exact files is hashed into a *modset digest* that behaves like a lockfile. Verdicts, deployments and rollbacks all attach to that digest.

**Bisect the delta, not the set.** Booting 300 mods and learning that it crashed names no culprit. But the last validated set is already proven good, and you typically change six mods, not three hundred — so delta-debugging the change finds the offender in about five boots instead of nine.

**Conflicts are remembered.** Every proven incompatibility becomes a permanent edge in a conflict graph and never costs another boot. Combined with reading mod metadata straight out of the jars, most conflicts eventually get caught before a JVM ever starts.

## Architecture

| Component | Responsibility |
|---|---|
| Slot scheduler | Owns the single ~10 GB memory budget. The only component permitted to start or stop a JVM. |
| Minecraft port proxy | Holds 25565–25567, answers server-list pings for sleeping servers, wakes them on join, forwards traffic once awake. |
| Manager | Reconciles the Google Sheet against reality: resolve, static-check, propose, validate, deploy, write back. |
| Conflict tester | Boots a candidate set in a throwaway session under a hard memory cap, judges it, destroys the directory. |
| Mod store | Content-addressed jar storage. Server and test directories are built from hardlinks into it. |
| Caddy | Public HTTPS, the website, and the read-only API behind it. |

Per-version state lives under `/var/minecraftai/26.1`, `26.2` and `26.3`. The scheduler, proxy, mod store and website are shared singletons, because the resources they arbitrate are global.

## Input and output

Desired mod lists come from a Google Sheet — one tab per Minecraft version, listing name, URL and intent. The sheet is an **input**, not the source of truth for what is deployed; when the two disagree the database wins and the sheet is corrected. Human-owned and system-owned columns are kept strictly separate so intent is never confused with observation. See [Sheet Contract](https://github.com/Pummelchen/MinecraftAI/wiki/Sheet-Contract).

The website lets a visitor pick a Minecraft version and see the mods actually loaded on it — name, category, and a link to the original mod page — along with which server is currently running and their measured latency to the host.

## Documentation

The full design lives in the [wiki](https://github.com/Pummelchen/MinecraftAI/wiki):

- [Architecture](https://github.com/Pummelchen/MinecraftAI/wiki/Architecture) — components, operating model, filesystem layout
- [Memory Budget](https://github.com/Pummelchen/MinecraftAI/wiki/Memory-Budget) — the binding constraint and its arithmetic
- [Modset Model](https://github.com/Pummelchen/MinecraftAI/wiki/Modset-Model) — digests, the content store, the conflict graph
- [Conflict Testing](https://github.com/Pummelchen/MinecraftAI/wiki/Conflict-Testing) — the two detection tiers and the session lifecycle
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
