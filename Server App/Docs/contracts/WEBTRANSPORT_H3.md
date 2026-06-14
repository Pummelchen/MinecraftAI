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

The Swift server exposes `/api/v1/transport/webtransport/preflight` so clients and operators can verify whether the live Swift-owned WebTransport endpoint is ready. Once ready, the macOS client uses the dedicated WebTransport session engine as its primary control plane.

## Option 2 Deployment

WebTransport is deliberately kept away from nginx.

- nginx keeps serving the website, operator/status HTTPS APIs, and release downloads.
- The Swift server app owns the WebTransport control endpoint on its own UDP port.
- Default public session URL: `https://pummelchen.91.99.176.243.nip.io:443/webtransport/v1/control`.
- The client discovers the session URL through `/api/v1/transport/webtransport/preflight`.
- The preflight payload must include `uses_nginx = false`.
- The preflight payload includes `server_public_key_x963_base64`, a public P-256 key pin derived from the live WebTransport certificate.

The Swift server can advertise a different endpoint with:

```text
MCPummelchenModServer serve --project-root <repo> --webtransport-host <host> --webtransport-port 443 --webtransport-path /webtransport/v1/control
```

## nginx Role

nginx remains the TCP HTTPS, static download, and website/API public edge. It is not in the WebTransport path. Current nginx HTTP/3 support does not expose the WebTransport session primitives the Swift app needs: Extended CONNECT dispatch, HTTP Datagram/Capsule forwarding, QUIC datagram access, or WebTransport stream ownership.

The chosen production path is Swift-owned QUIC/H3/WebTransport on UDP `443`. nginx keeps serving ordinary TCP HTTPS traffic on `443` without owning the UDP WebTransport control plane.

## Session Engine

The Swift session engine is implemented by `PummelchenWebTransportService` on the server and `ClientWebTransportControlChannel` on macOS. The service uses QUIC/TLS production mode, HTTP/3 Extended CONNECT, WebTransport bidirectional streams, and QUIC datagram negotiation. Requests are authenticated JSON control frames on WebTransport streams. Datagrams are negotiated for protocol capability and future low-priority telemetry, but production control traffic does not trust or echo datagram payloads. Current release metadata also moves over WebTransport so clients learn target versions through the same authenticated channel. Large immutable release files still stay on nginx download URLs and are verified by SHA-256 after download.

Control stream payloads are bounded to 512 KiB on both server and client. Individual stored control events remain bounded to 16 KiB so a single event cannot flood the event store or UI. Larger data movement belongs in release files served by nginx and verified with SHA-256.

For the WebTransport QUIC/TLS endpoint, the Swift server uses the Let's Encrypt leaf certificate (`cert.pem`) instead of the full browser chain. The trusted nginx HTTPS preflight provides the public key pin, and the macOS client verifies the QUIC certificate signature against that pin. This keeps the QUIC handshake compact while preserving a trusted bootstrap path.

Supported stream actions:

- `fetch_events`
- `current_release`
- `ack_event`
- `register_client`
- `status_report`
- `sync_run_report`
- `heartbeat_report`
- `inventory_upload`
- `diagnostics_upload`
- `defaults_events_upload`

Authenticated HTTPS control APIs may remain available for operator tooling and website diagnostics. The production macOS client does not use them as a silent fallback. If WebTransport is unavailable, the client records and displays the degraded/cannot-connect state so the transport problem is visible and fixable.

## Production Gate

The deployment is production-ready when:

- `/api/v1/transport/webtransport/preflight` returns `ready = true`;
- preflight includes `server_public_key_x963_base64`;
- the Swift server app logs `pummelchen_webtransport=ready`;
- the macOS client can open a WebTransport session to the advertised URL;
- current release metadata is fetched over WebTransport;
- control events `release_available`, `sync_required`, `defaults_changed`, and `client_sync_requested` are delivered over WebTransport;
- acknowledgements, heartbeat/status reports, inventory, diagnostics, sync run reports, and defaults reports are accepted over WebTransport;
- release downloads continue through nginx and pass SHA-256 manifest verification.
