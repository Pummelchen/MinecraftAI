# Pummelchen Client Identity Contract

This contract freezes the client identity/token model for the Swift migration. It is a Phase 0 contract only; existing production scripts remain authoritative until later cutover phases.

## Identity

Each installed client has:

- `client_id`: random UUID string generated on first run.
- `client_secret`: random 256-bit token generated on first run.
- `created_at`: ISO-8601 timestamp.
- `last_rotated_at`: ISO-8601 timestamp, nullable for first private builds.

## Storage

Preferred final storage:

- `client_id` in local app configuration.
- `client_secret` in macOS Keychain.

Allowed during early private test builds:

- locked-down local token file under the Pummelchen app support directory.
- file permissions must be owner read/write only.
- the token file must never be included in the DMG, release ZIP, Git, logs, or diagnostics.

## Transport And Request Authentication

Client/server API and near-realtime control traffic must target HTTP/3 over QUIC. Client write/report APIs must use HTTP/3 over TLS and include:

```http
Authorization: Bearer <client_secret>
X-Pummelchen-Client-ID: <client_id>
```

Client read-only release downloads remain public static files served by nginx.

HTTP/2 HTTPS polling is allowed only as an early private-build compatibility fallback for networks that block UDP/QUIC. It must use the same authentication headers for write/report APIs.

## Rotation And Revocation

- Server can mark a client token as revoked.
- Client must generate a new token only through an explicit repair/re-enrollment path.
- Diagnostics uploads must redact `client_secret`.
- Server logs may retain `client_id`, but not `client_secret`.

## Non-Goals

- No direct DuckDB access from clients.
- No unauthenticated client write APIs.
- No shared global client token for production.
- No large file downloads over the bidirectional QUIC control channel.
