# WebTransport Over HTTP/3 Contract

Pummelchen targets WebTransport over HTTP/3 for near-realtime client/server control traffic. The implementation follows `draft-ietf-webtrans-http3-15`, the latest active IETF working group draft checked for this project, and keeps the protocol constants in `PummelchenCore/WebTransportH3.swift` so the macOS client and Debian server use one shared contract.

## Required Wire Features

A production WebTransport session is only valid when the server proves all of the following:

- HTTP/3 SETTINGS include `SETTINGS_WT_ENABLED > 0`.
- HTTP/3 SETTINGS include `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`.
- HTTP/3 SETTINGS include `SETTINGS_H3_DATAGRAM = 1`.
- QUIC transport parameters include `max_datagram_frame_size > 0`.
- QUIC transport parameters include `reset_stream_at`.
- The control session is established with Extended CONNECT and `:protocol = webtransport-h3`.

The Swift server exposes `/api/v1/transport/webtransport/preflight` so clients and operators can verify whether the live Swift-owned WebTransport endpoint is ready before retiring the current HTTP/3 long-poll control path.

## Option 2 Deployment

WebTransport is deliberately kept away from nginx.

- nginx keeps serving the website, normal HTTPS APIs, and release downloads.
- The Swift server app owns the WebTransport control endpoint on its own UDP port.
- Default public session URL: `https://pummelchen.91.99.176.243.nip.io:7443/webtransport/v1/control`.
- The client discovers the session URL through `/api/v1/transport/webtransport/preflight`.
- The preflight payload must include `uses_nginx = false`.

The Swift server can advertise a different endpoint with:

```text
pummelchen-server serve --project-root <repo> --webtransport-host <host> --webtransport-port 7443 --webtransport-path /webtransport/v1/control
```

## nginx Role

nginx remains the HTTPS, static download, and optional ordinary HTTP/3 public edge. It is not in the WebTransport path. Current nginx HTTP/3 support does not expose the WebTransport session primitives the Swift app needs: Extended CONNECT dispatch, HTTP Datagram/Capsule forwarding, QUIC datagram access, or WebTransport stream ownership.

The chosen production path is Swift-owned QUIC/H3/WebTransport on the dedicated UDP port. nginx can keep serving ordinary HTTP traffic without affecting the WebTransport control plane.

## Retirement Gate

The existing authenticated control APIs must not be removed until:

- `/api/v1/transport/webtransport/preflight` returns `ready = true`;
- the macOS client can open a WebTransport session and record a successful negotiated session;
- control events `release_available`, `sync_required`, `defaults_changed`, and `client_sync_requested` are delivered over WebTransport;
- acknowledgements, heartbeats, inventory, diagnostics, and sync run reports are sent over the same WebTransport control plane;
- tests cover update latency, reconnect, missed-event replay, corrupt download repair, and blocked-UDP fallback behavior.
