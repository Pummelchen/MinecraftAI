# Master edge

One Caddy instance owns ports 80 and 443 for this VPS, terminates TLS and
HTTP/3, and routes by Host header to each project's own web server. Deployed to
`/var/caddy`. **Live.**

It holds no project's web configuration. Roots, headers, cache policy, API
routes and deploys all stay inside the project that owns them; an entry here is
four lines saying which hostname goes to which port.

That boundary is deliberate. This host previously ran one shared
`/etc/caddy/Caddyfile` holding several projects' real configs, and each
project's deploy overwrote the others'. A routing entry is not something a
deploy rewrites, so that failure cannot recur.

```
                        minecraft.*.nip.io ──▶ 127.0.0.1:8801  minecraftai-caddy
:80 :443  master Caddy ─┬ roomcad.*.nip.io ──▶ 127.0.0.1:8443  roomcad-caddy (https)
 TLS + h3               ├─── xaios.*.nip.io ──▶ 127.0.0.1:8090  xaios-caddy
                        └─ <next>.*.nip.io  ──▶ 127.0.0.1:88xx  <next>'s own server
```

Every project gets its own hostname on the same IP — `nip.io` accepts arbitrary
prefixes — and a real Let's Encrypt certificate, with no port in any URL.

## Why a master edge

Ports 80 and 443 can only be held once, and Let's Encrypt validates on nothing
else — so whichever process owns them is the only one that can obtain
certificates. Centralising that means every project gets automatic HTTPS on a
clean URL with no port number, instead of each fighting for a certificate it
cannot get.

## Layout

| Path | Purpose |
|---|---|
| `Caddyfile` | Master config. Global options and one import. Adding a project never edits this. |
| `projects/*.caddy` | One fragment per project. Owned by that project. |
| `projects/EXAMPLE.caddy.template` | Copy this to start a new project. |
| `systemd/caddy.service.d/override.conf` | Points the packaged unit at `/var/caddy`. |
| `scripts/validate.sh` | Validates everything. Needs no root. |
| `scripts/test-edge.sh` | Starts the real config against a scratch root and stub API, then asserts routing, headers and the sensitive-file block. Needs no root. |
| `scripts/install.sh` | Stages onto the VPS. Starts nothing, takes no port. |
| `MIGRATION.md` | Taking 80 and 443 from whatever holds them now. |

Import paths are relative to the Caddyfile, so the same config validates from a
checkout and runs from `/var/caddy`.

## Adding a project

```sh
cp projects/EXAMPLE.caddy.template projects/myproject.caddy
```

Edit the hostname and upstream, then:

```sh
scripts/validate.sh
```

```sh
scripts/test-edge.sh
```

Any `<name>.91.99.176.243.nip.io` resolves to this host, so the prefix is free
to choose. It ends up in the certificate, so pick something stable.

Serve on 443 unless there is a specific reason not to. Caddy will happily bind
a non-standard port and can still obtain a certificate for it — the master
holds 80 and 443, which is where validation happens — but a URL with a port in
it is a URL people mistype, and the master exists precisely so no project needs
one.

## Conventions worth keeping

**Environment indirection.** Paths, upstreams and hostnames use the
`{$VAR:default}` form. Defaults are the production values; the overrides are
what let the config be validated and exercised without root. A config that can
only be checked on the production host is a config nobody checks.

**Only the master does TLS.** A project running its own Caddy needs
`auto_https off`, or it will attempt ACME, fail because it cannot bind 80 or
443, and retry forever.

**`trusted_proxies` everywhere.** Without it every project behind the master
logs `127.0.0.1` as the client address.

**Forward the client's Host.** `header_up Host {host}` on every entry. Without
it Caddy sends the dial address upstream, and a project whose own config matches
a specific hostname then matches nothing and returns a bare empty 200 — success
status, no body, nothing logged as an error. RoomCAD hit exactly this; projects
that match any host hide the bug.

**Order-sensitive directives go inside `route`.** Caddy sorts directives by its
own standard order, not the order written. A `respond` guarding sensitive paths
placed next to `handle` runs *after* `file_server` and serves the files it was
meant to block — silently, with a 200. `scripts/test-edge.sh` catches this; it
found exactly that bug in the first draft of `minecraftai.caddy`.

## Does a project need its own Caddy?

Usually not. A fragment can serve static files and proxy an app directly, which
is what `projects/minecraftai.caddy` does — the mod site is static files plus
one API route, and a second Caddy would add a process and a hop for nothing.

A dedicated instance earns its place when a project needs its own cache and
header policy, independent reloads, a pinned Caddy version, or runs in a
container. Decide per project.
