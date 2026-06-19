# MCPummelchenModClient Identity Contract

This contract freezes the client identity/token model for the Swift/DuckDB production system.

## Identity

Each installed client has:

- `client_id`: random UUID string generated on first run.
- `client_secret`: random 256-bit token generated on first run.
- `created_at`: ISO-8601 timestamp.
- `last_rotated_at`: ISO-8601 timestamp, nullable for first private builds.

## Storage

Preferred storage:

- `client_id` in local app configuration.
- `client_secret` in macOS Keychain.

Private build bootstrap:

- A private DMG build may include a `client-api-token` resource when `PUMMELCHEN_CLIENT_API_TOKEN` is provided during packaging.
- The token resource is a bootstrap credential for the private player group and must not be committed to Git, printed in logs, included in diagnostics, or written to public release metadata.
- The packaged token resource must be owner read/write only inside the staged app bundle before signing.
- Environment and Info.plist token values override the bundled resource for operator tests and emergency repair builds.

## Transport And Request Authentication

Client/server API and near-realtime control traffic use nginx-served HTTPS endpoints. Write/report requests and live update polling must authenticate with:

```http
Authorization: Bearer <client_secret>
X-Pummelchen-Client-ID: <client_id>
```

Client read-only release downloads remain public static files served by nginx. The same nginx HTTPS edge also proxies authenticated `/api/v1/control/*` and `/api/v1/clients/*` requests to the Swift server app.

## Control Events

The Swift server publishes control metadata through `/api/v1/control/info`. The client uses `ClientControlChannel` over HTTPS for event delivery, acknowledgements, sync run reports, inventory uploads, diagnostics uploads, defaults reports, and status/heartbeat messages.

Events that require an immediate client sync:

- `release_available`
- `sync_required`
- `defaults_changed`
- `client_sync_requested`

Informational events that do not trigger downloads by themselves:

- `server_message`
- `server_restart_notice`
- `health_update`

When a sync event is received, the client fetches the current release metadata, verifies the manifest, downloads only missing or corrupt files, reports the result to the server over HTTPS, and acknowledges the event.

## Rotation And Revocation

- Server can mark a client token as revoked.
- Client must rotate away from a token only through an explicit repair/re-enrollment path.
- Diagnostics uploads must redact `client_secret`, bootstrap tokens, and authorization headers.
- Server logs may retain `client_id`, but not `client_secret`, bootstrap tokens, or authorization headers.

## Non-Goals

- No direct access from clients to the server-side DuckDB database.
- No unauthenticated client write APIs.
- No token values in Git, public website assets, public release metadata, logs, or diagnostics.
- No large file downloads through the authenticated control API.
