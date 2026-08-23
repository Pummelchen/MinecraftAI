# Taking over ports 80 and 443

The master edge only works if it owns 80 and 443. Something else holds them
today, and every website on this host depends on it. **Read this fully before
running anything.** A mistake here is a total outage, not a degraded service.

Nothing in `install.sh` starts Caddy or touches a port. Cutover is deliberate
and manual.

## 1. Find out what is there

```sh
sudo ss -tlnp '( sport = :80 or sport = :443 )'
sudo ss -ulnp '( sport = :443 )'
```

The UDP query matters: if the incumbent already serves HTTP/3, it holds UDP 443
as well, and a TCP-only check will miss it.

Then capture what it serves, because every hostname it answers for has to keep
working afterwards:

```sh
sudo nginx -T 2>/dev/null | grep -E 'server_name|listen|proxy_pass'
```

```sh
sudo apachectl -S 2>/dev/null
```

```sh
sudo caddy list-modules --versions 2>/dev/null | head -1
```

Write down, per hostname: the upstream it proxies to or the directory it
serves, and where its certificate currently lives.

## 2. Which case are you in?

### The incumbent is Caddy — easiest

Merge rather than replace. Move its site blocks into `projects/` as one file
per site, point its unit at `/var/caddy/Caddyfile`, and reload. Certificates in
its data directory can be moved across, or simply re-issued.

Downtime: a graceful reload. Effectively zero.

### The incumbent is nginx or Apache — the real migration

Each vhost becomes a project fragment. Two ways to land it:

- **Reverse-proxy to it.** Leave the service running but rebind it to a
  loopback port, and give it a fragment that proxies there. Least disruptive:
  its config keeps working untouched.
- **Reimplement it in Caddy.** Cleaner long-term, more work, more risk per
  site. Reasonable for simple static vhosts, not for anything with elaborate
  rewrite rules.

Rebinding is the better first move. Convert later, one site at a time, with
the master already stable.

## 3. Prepare, before any window

```sh
sudo ./caddy/scripts/install.sh
```

Every hostname the incumbent serves must have a fragment in `/var/caddy/projects/`.
Check that they are all present and that the config still validates:

```sh
sudo CADDY_LOG_DIR=/var/log/caddy caddy validate --config /var/caddy/Caddyfile --adapter caddyfile
```

Confirm the firewall allows **UDP 443** as well as TCP. HTTP/3 runs over QUIC on
UDP; opening only TCP gives a site that works while silently never using h3.

## 4. Cut over

Pick a quiet window. Have the rollback command in a second terminal, typed and
unexecuted, before you start.

```sh
sudo systemctl stop <incumbent> && sudo systemctl start caddy
```

Then verify **every** hostname, not just the new one:

```sh
curl -sSI https://minecraft.91.99.176.243.nip.io | head -20
```

```sh
curl -sS --http3 -o /dev/null -w '%{http_version}\n' https://minecraft.91.99.176.243.nip.io
```

The second command prints `3` when HTTP/3 is working. If curl lacks HTTP/3
support, look for an `Alt-Svc: h3=` header in the first command instead.

Certificate issuance for a new hostname takes a few seconds on first request.
Watch it happen:

```sh
sudo journalctl -u caddy -f
```

## 5. Rollback

If anything is wrong, go back immediately. Diagnose afterwards, not during.

```sh
sudo systemctl stop caddy && sudo systemctl start <incumbent>
```

The incumbent's config was never modified, so this is a clean reversal.

## Adding a project later

No window, no risk:

```sh
sudo cp myproject.caddy /var/caddy/projects/
```

```sh
sudo systemctl reload caddy
```

A reload with an invalid config **fails and keeps the running config**, so a
bad fragment is a failed deploy rather than an outage. Validate first anyway:

```sh
sudo CADDY_LOG_DIR=/var/log/caddy caddy validate --config /var/caddy/Caddyfile --adapter caddyfile
```

## Certificate rate limits

Let's Encrypt allows 50 certificates per registered domain per week. This is
only comfortable if `nip.io` is on the Public Suffix List, which makes each
`<name>.nip.io` its own registered domain rather than all of them sharing one
bucket with every nip.io user in the world.

It is believed to be listed — that is why nip.io works with Let's Encrypt at
all — but **verify before a dozen projects depend on it**, and do not use
`on_demand_tls` without an `ask` endpoint: every hostname under
`*.91.99.176.243.nip.io` points at this host, so anyone could trigger issuance
by connecting with an arbitrary SNI and exhaust the limit.

The durable answer is a domain you control plus a wildcard certificate via
DNS-01: one certificate covering every project, no per-hostname issuance, and
no rate-limit exposure.
