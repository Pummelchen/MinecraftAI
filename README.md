# MinecraftAI

A mod release and conflict-validation system for three NeoForge Minecraft servers — one Swift engine, behind Caddy.

> **Status: design stage**, with one exception — the [master Caddy edge](caddy/) is built, tested and **live on the VPS**. The engine itself is not implemented. The previous implementation was retired — see [Archive](#the-retired-v1-system).

## The problem

Three Minecraft versions — 26.1, 26.2 and 26.3 — each run NeoForge with roughly 300 mods. Because mods do not all support every Minecraft version, each server carries a different collection.

That part is bookkeeping. The hard part is this: **mods that are individually compatible with a server version can still be incompatible with each other.** Two mods boot fine together until a third joins them; a mixin collides; two mods claim the same registry ID. Nothing in a mod's metadata reliably predicts it, so the only trustworthy answer comes from actually starting a server with that exact set of files and seeing whether it survives.

So no mod set reaches a live server until a throwaway session has proven it boots clean.

## Approach

**The mod set is the unit, not the mod.** A mod is never validated on its own — it is validated as part of a set. The list of exact files is hashed into a *modset digest* that behaves like a lockfile. Verdicts, deployments and rollbacks all attach to that digest, so there is no way to quietly change a file and keep a validation result.

**Bisect the change, not the set.** Booting 300 mods and learning that it crashed names no culprit. But the last validated set is already proven good, and you typically change six mods rather than three hundred — so delta-debugging just the change finds the offender in two or three rounds, with both branches of each split tested in parallel.

**Conflicts are remembered.** Every proven incompatibility becomes a permanent edge in a conflict graph and never costs another boot again. Combined with reading mod metadata straight out of the jars — which catches missing dependencies, duplicate mod IDs, and mods that explicitly declare each other incompatible — most conflicts eventually get caught before a JVM ever starts.

**A Minecraft version is data, never code.** No version string appears in source, configuration, a systemd unit, a Caddy route, or the website. Adding 26.4 when Mojang ships it is one command and a row.

## Stack

| Layer | Choice |
|---|---|
| Engine | Swift 6.3.3 — a single process handling all versions and the website API |
| State | Local SQLite in WAL mode, via GRDB |
| Web server | Latest Caddy on port 8877, HTTP/3 and QUIC |
| Servers | One systemd-managed NeoForge JVM per version, unit generated from a template |
| Input | Google Sheets, one tab per version, read and written by the engine |

All three servers run continuously on 25565–25567. Conflict tests are additional short-lived servers on scratch ports, created and destroyed per run.

### One engine, not one per version

v1 ran three Swift services on three loopback ports, one per Minecraft version — three systemd units, three Caddy route blocks, three copies of every fix, and nowhere to put logic spanning versions. The engine instead holds every version in one process, so **adding a Minecraft version creates no service and changes no Caddy configuration.** See [Adding a Version](https://github.com/Pummelchen/MinecraftAI/wiki/Adding-a-Version).

## The edge

A **master Caddy** owns ports 80 and 443 for the whole VPS, terminates TLS and HTTP/3, and routes by hostname to each project. Config in [`caddy/`](caddy/).

| Hostname | Project |
|---|---|
| [`minecraft.91.99.176.243.nip.io`](https://minecraft.91.99.176.243.nip.io) | this one — `/var/minecraftai` |
| [`roomcad.91.99.176.243.nip.io`](https://roomcad.91.99.176.243.nip.io) | `/var/roomcad` |
| [`xaios.91.99.176.243.nip.io`](https://xaios.91.99.176.243.nip.io) | `/var/xaios_updater` |

This exists because ports 80 and 443 can only be held once, and Let's Encrypt validates on nothing else, so whichever process owns them is the only one that can obtain certificates. Centralising that gives every project automatic HTTPS on a clean URL with no port number, instead of each fighting for a certificate it cannot get.

Adding a project is one file in `caddy/projects/` and a reload. Cutting the master over from whatever currently holds 80 and 443 is the one risky step, and has its own runbook: [`caddy/MIGRATION.md`](caddy/MIGRATION.md).

```bash
caddy/scripts/test-edge.sh
```

## Documentation

The full design lives in the [wiki](https://github.com/Pummelchen/MinecraftAI/wiki):

- [Architecture](https://github.com/Pummelchen/MinecraftAI/wiki/Architecture) — shape, components, filesystem layout
- [Engine](https://github.com/Pummelchen/MinecraftAI/wiki/Engine) — the Swift process, dependencies, command surface, API
- [Adding a Version](https://github.com/Pummelchen/MinecraftAI/wiki/Adding-a-Version) — how a new Minecraft version arrives
- [Modset Model](https://github.com/Pummelchen/MinecraftAI/wiki/Modset-Model) — digests, the content store, the conflict graph
- [State Database](https://github.com/Pummelchen/MinecraftAI/wiki/State-Database) — SQLite in WAL mode: configuration, contents, backup
- [Conflict Testing](https://github.com/Pummelchen/MinecraftAI/wiki/Conflict-Testing) — detection tiers and the session lifecycle
- [Bisection](https://github.com/Pummelchen/MinecraftAI/wiki/Bisection) — fault localization and its cost model
- [Sheet Contract](https://github.com/Pummelchen/MinecraftAI/wiki/Sheet-Contract) — column ownership rules
- [Edge and TLS](https://github.com/Pummelchen/MinecraftAI/wiki/Edge-and-TLS) — Caddy, HTTP/3, and the certificate problem
- [Website](https://github.com/Pummelchen/MinecraftAI/wiki/Website) — pages, API, and what latency can honestly be measured
- [Deployment and Rollback](https://github.com/Pummelchen/MinecraftAI/wiki/Deployment-and-Rollback) — the live gate
- [Open Decisions](https://github.com/Pummelchen/MinecraftAI/wiki/Open-Decisions) — what is still undecided

## The retired v1 system

The previous implementation — three Swift packages, DuckDB, Caddy, per-version systemd units — was retired before this redesign. It is preserved in full:

```bash
git checkout v1-retired
```

Also available as the branch `archive/v1`. Its production contracts are worth reading as prior art on release immutability, manifest verification and world-reset safety. Its architecture is deliberately not carried forward. See [v1 Archive](https://github.com/Pummelchen/MinecraftAI/wiki/v1-Archive).
