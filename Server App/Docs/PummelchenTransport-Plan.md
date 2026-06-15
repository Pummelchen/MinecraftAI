# PummelchenTransport — Pure-Swift QUIC + HTTP/3 + WebTransport

## Context
Quiver (56K lines, vendored at `Git/Server App/Vendor/Quiver/`) doesn't comply with draft-ietf-webtrans-http3-15. Instead of patching it, we're replacing it with a purpose-built pure-Swift implementation: `PummelchenTransport`. macOS-only (arm64), using CryptoKit + Security.framework for crypto. Target: ~18K source lines (67% reduction). Full draft-15 compliance from day one.

## Module Structure

```
PummelchenTransport/
  Package.swift
  Sources/
    PummelchenQuicCore/         ~1,800 lines — Wire primitives (Foundation only)
    PummelchenQuicCrypto/       ~3,500 lines — TLS 1.3 + QUIC crypto (CryptoKit, Security.framework)
    PummelchenQuic/             ~7,500 lines — QUIC transport (Dispatch, POSIX sockets)
    PummelchenHTTP3/            ~5,200 lines — HTTP/3 + WebTransport
  Tests/
    PummelchenQuicCoreTests/
    PummelchenQuicCryptoTests/
    PummelchenQuicTests/
    PummelchenHTTP3Tests/
```

**Total: ~18,200 source lines** (vs Quiver's 56,014)

## Key Design Decisions

- **No external dependencies** — CryptoKit, Security.framework, Dispatch, POSIX sockets only
- **Single cipher suite** — TLS_AES_128_GCM_SHA256 only (CryptoKit AES.GCM)
- **X25519 key exchange** — via CryptoKit Curve25519.KeyAgreement
- **No QPACK** — hand-encode 5 CONNECT pseudo-headers using static table + literals
- **No 0-RTT / session resumption** — simpler TLS state machine
- **No connection migration** — fixed 4-tuple
- **Fixed 1200-byte MTU** — RFC 9000 minimum, no PMTUD needed
- **NewReno congestion control** — simplified per RFC 9002
- **X.509 via Security.framework** — `SecTrust` handles certificate validation
- **UDP via DispatchSource** — POSIX socket + `makeReadSource`, no SwiftNIO dependency

## API Compatibility

The new types preserve all names used by the app code. App changes = import statement updates only:
- `import HTTP3` → `import PummelchenHTTP3`
- `import QUIC` → `import PummelchenQuic`
- `import QUICCrypto` → `import PummelchenQuicCrypto`

### Types imported by Server (`MCPummelchenModServerCore/PummelchenWebTransportService.swift`)
| Current Type (Quiver) | New Type (PummelchenTransport) | Module |
|---|---|---|
| `QUICConfiguration` | `QUICConfiguration` | `PummelchenQuic` |
| `QUICConfiguration.production { ... }` | `QUICConfiguration.production { ... }` | `PummelchenQuic` |
| `TLSConfiguration` | `TLSConfiguration` | `PummelchenQuicCrypto` |
| `TLS13Handler` | `TLS13Handler` | `PummelchenQuicCrypto` |
| `WebTransportServer` | `WebTransportServer` | `PummelchenHTTP3` |
| `WebTransportConfiguration` | `WebTransportConfiguration` | `PummelchenHTTP3` |
| `WebTransportServer.ServerOptions` | `WebTransportServer.ServerOptions` | `PummelchenHTTP3` |
| `WebTransportSession` | `WebTransportSession` | `PummelchenHTTP3` |
| `WebTransportStream` | `WebTransportStream` | `PummelchenHTTP3` |

### Types imported by Client (`MCPummelchenModClientCore/ClientWebTransportControlChannel.swift`, `PooledWebTransportChannel.swift`)
| Current Type (Quiver) | New Type (PummelchenTransport) | Module |
|---|---|---|
| `QUICEndpoint` | `QUICEndpoint` | `PummelchenQuic` |
| `QUIC.SocketAddress` | `SocketAddress` | `PummelchenQuicCore` |
| `QUICConnectionProtocol` | `QUICConnectionProtocol` | `PummelchenQuic` |
| `QUICStreamProtocol` | `QUICStreamProtocol` | `PummelchenQuic` |
| `WebTransportClient` | `WebTransportClient` | `PummelchenHTTP3` |
| `WebTransportClient.Configuration` | `WebTransportClient.Configuration` | `PummelchenHTTP3` |
| `WebTransportSession` | `WebTransportSession` | `PummelchenHTTP3` |
| `WebTransportStream` | `WebTransportStream` | `PummelchenHTTP3` |
| `TLSConfiguration.client(...)` | `TLSConfiguration.client(...)` | `PummelchenQuicCrypto` |
| `TLS13Handler` | `TLS13Handler` | `PummelchenQuicCrypto` |

---

## Phase 1: Wire Primitives (`PummelchenQuicCore`, ~1,800 lines)

**Task 1: Package scaffolding**
- Create `PummelchenTransport/Package.swift` with 4 module targets + 4 test targets
- Empty stub files for each module
- Verify: `swift build` succeeds

**Task 2: Varint + ConnectionID + SocketAddress**
- `Varint.swift` — QUIC variable-length integer encode/decode (RFC 9000 Section 16)
- `ConnectionID.swift` — 0-20 byte connection ID, random generation
- `SocketAddress.swift` — IPv4/IPv6 address + port
- `ProtocolConstants.swift` — version numbers, limits
- Verify: round-trip tests for all varint sizes, overflow detection

**Task 3: Frame types + codec**
- `Frame.swift` — all frame structs/enum: PADDING, PING, ACK, RESET_STREAM, STOP_SENDING, CRYPTO, STREAM, MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS, DATA_BLOCKED, STREAMS_BLOCKED, NEW_CONNECTION_ID, RETIRE_CONNECTION_ID, CONNECTION_CLOSE, HANDSHAKE_DONE, DATAGRAM, **RESET_STREAM_AT (0x24)**
- `FrameCodec.swift` — encode/decode dispatch
- Verify: encode/decode round-trip for every frame type

**Task 4: Packet headers + transport parameters**
- `PacketHeader.swift` — Long (Initial, Handshake) + Short (1-RTT) header encode/decode
- `PacketCodec.swift` — packet number encode/decode, coalesced packet split
- `TransportParameters.swift` — encode/decode including `max_datagram_frame_size` (0x20) and `reset_stream_at` (0x17f7586d2cb571)
- `Errors.swift` — QUIC transport error codes
- Verify: parse Initial header from RFC 9000 Appendix A vectors

## Phase 2: Cryptography (`PummelchenQuicCrypto`, ~3,500 lines)

**Task 5: Key schedule + AEAD + header protection**
- `QUICKeySchedule.swift` — HKDF-SHA256 key derivation (RFC 9001 Section 5) via CryptoKit
- `InitialSecrets.swift` — derive initial client/server secrets from DCID (QUIC v1 salt)
- `AEAD.swift` — AES-128-GCM seal/open via CryptoKit, nonce XOR with packet number
- `HeaderProtection.swift` — AES-128-ECB mask via CryptoKit
- `CryptoState.swift` — per-level key state (Initial, Handshake, 1-RTT), key update
- Verify: initial secrets against RFC 9001 Appendix A.1 vectors, AEAD round-trip

**Task 6: TLS 1.3 message codec**
- `TLSMessageCodec.swift` — ClientHello, ServerHello, EncryptedExtensions, Certificate, CertificateVerify, Finished
- `TLSConfiguration.swift` — cert paths, ALPN, server name, peer key pinning, system trust store
- `TLS13Provider.swift` — protocol interface for QUIC layer
- Verify: encode/decode round-trip for all message types

**Task 7: TLS 1.3 state machines**
- `TLSClientStateMachine.swift` — build ClientHello (X25519 key share, quic_transport_parameters ext 0x0039, ALPN), process ServerHello → handshake keys → process server Finished → app keys
- `TLSServerStateMachine.swift` — process ClientHello → build ServerHello → send EncryptedExtensions + Certificate + CertificateVerify + Finished → process client Finished
- `X509Validator.swift` — Security.framework: `SecTrust` evaluation, public key extraction for pinning
- Verify: full client↔server handshake over in-memory pipe

**Task 8: TLS handler + crypto stream**
- `TLS13Handler.swift` — bridges CRYPTO frame data to/from state machines, manages per-level buffers, exports transport params
- `CryptoStreamHandler.swift` — segment handshake messages into CRYPTO frames, reassemble received fragments
- `KeyUpdate.swift` — 1-RTT key rotation
- Verify: full handshake loopback with real packet construction

## Phase 3: QUIC Transport (`PummelchenQuic`, ~7,500 lines)

**Task 9: Stream layer**
- `StreamState.swift` — state machine (idle → open → half-closed → closed)
- `DataStream.swift` — send/receive buffers, offset tracking, FIN, async read/write API
- `FlowController.swift` — stream + connection level MAX_DATA/MAX_STREAM_DATA
- `StreamManager.swift` — stream creation, ID allocation (client bidi = 0 mod 4), limits
- Verify: stream state transitions, flow control enforcement

**Task 10: Loss detection + congestion control**
- `SentPacketTracker.swift` — track sent packets (time, size, ack-eliciting, encryption level)
- `AckProcessor.swift` — process ACK frames, mark acked/lost, compute RTT
- `LossDetector.swift` — time + packet-threshold loss detection (RFC 9002 Section 6)
- `RTTEstimator.swift` — SRTT/varRTT/minRTT
- `CongestionController.swift` — NewReno (slow start, congestion avoidance, recovery)
- `PTOTimer.swift` — probe timeout calculation
- Verify: PTO calculation, NewReno cwnd behavior

**Task 11: Connection handler**
- `ConnectionState.swift` — idle → handshaking → connected → closing → closed
- `ConnectionHandler.swift` — packet processing, CRYPTO routing, frame generation, coalesced packets
- `FrameProcessor.swift` — inbound frame dispatch (ACK, STREAM, CRYPTO, MAX_DATA, MAX_STREAMS, CONNECTION_CLOSE, DATAGRAM, RESET_STREAM_AT)
- `PacketBuilder.swift` — pack frames into MTU-sized packets across encryption levels
- `ResetStreamAt.swift` — reliable reset: deliver data up to reliableSize before signaling reset
- Verify: frame dispatch, RESET_STREAM_AT reliable delivery

**Task 12: UDP transport + endpoint**
- `UDPSocket.swift` — POSIX socket + DispatchSource.makeReadSource, dual-stack IPv4/IPv6
- `QuicEndpoint.swift` — public actor: `dial(address:timeout:)` + `serve(host:port:)`, connection routing by DCID
- `ConnectionRouter.swift` — DCID-to-connection dispatch, new connection creation
- `ManagedConnection.swift` — concrete connection: I/O loop, packet send/receive, stream open/accept, datagram send/receive
- `TimerManager.swift` — ACK delay, PTO, idle timeout coordination
- `QuicConfiguration.swift` — config struct matching current API
- `QuicConnection.swift` — `QUICConnectionProtocol` + `QUICStreamProtocol` definitions
- Verify: UDP echo loopback, client dial + server accept, multi-stream data transfer

## Phase 4: HTTP/3 + WebTransport (`PummelchenHTTP3`, ~5,200 lines)

**Task 13: HTTP/3 framing + SETTINGS + minimal QPACK**
- `HTTP3Frame.swift` — DATA, HEADERS, SETTINGS, GOAWAY
- `HTTP3FrameCodec.swift` — frame encode/decode
- `HTTP3Settings.swift` — all WT-relevant settings: WT_ENABLED (0x2c7cf000), ENABLE_CONNECT_PROTOCOL (0x08), H3_DATAGRAM (0x33), WT_INITIAL_MAX_STREAMS_UNI/BIDI, WT_INITIAL_MAX_DATA
- `MinimalQPACK.swift` — hand-encode `:method=CONNECT`, `:protocol=webtransport-h3`, `:scheme=https`, `:authority`, `:path` + custom headers. Decode `:status` responses. Static table only, no Huffman, no dynamic table.
- `ExtendedConnect.swift` — RFC 9220 request/response construction
- `HTTP3Error.swift` — error codes
- Verify: SETTINGS round-trip, CONNECT header encode/decode

**Task 14: HTTP/3 connection**
- `HTTP3Connection.swift` — control uni-stream (type 0x00), SETTINGS exchange, QPACK streams (empty)
- `HTTP3Connection+Server.swift` — accept bidi streams, detect Extended CONNECT, dispatch to WT
- `HTTP3Connection+Client.swift` — send Extended CONNECT, read response
- `HTTP3Connection+WebTransport.swift` — session registry, stream routing (0x41 bidi, 0x54 uni), datagram routing (quarter stream ID)
- `HTTP3Connection+Streams.swift` — uni-stream type identification
- Verify: control stream setup, SETTINGS exchange, uni-stream routing

**Task 15: WebTransport layer**
- `WebTransportServer.swift` — `listen(host:port:)`, `stop()`, `incomingSessions` AsyncStream
- `WebTransportClient.swift` — `initialize()`, `connect(authority:path:headers:)`, `close()`
- `WebTransportSession.swift` — CONNECT stream management, bidi/uni stream dispatch, datagram routing, close/drain capsules, **flow control capsules** (WT_MAX_STREAMS, WT_MAX_DATA, WT_STREAMS_BLOCKED, WT_DATA_BLOCKED)
- `WebTransportStream.swift` — session ID prefix, read/write/closeWrite API, **RESET_STREAM_AT with reliableSize >= header size**
- `WebTransportConfiguration.swift` — QUIC config + max sessions + HTTP/3 settings preset
- `WebTransportCapsule.swift` — CLOSE (0x2843), DRAIN (0x78ae), + 6 flow control capsules per draft-15
- `WebTransportError.swift` — error code mapping with correct base `0x52e4a40fa8db` + non-linear formula, all 5 named error codes
- Verify: full server+client loopback — session establish, bidi stream JSON exchange, capsule close/drain

## Phase 5: Integration + Migration

**Task 16: Swap Quiver for PummelchenTransport**
- Update server `Package.swift`: replace Quiver dependency with PummelchenTransport
- Update client `Package.swift`: same
- Update imports in app code (HTTP3 → PummelchenHTTP3, QUIC → PummelchenQuic, QUICCrypto → PummelchenQuicCrypto)
- Build + test server app, client app, shared module
- Full DMG build + deploy

---

## Verification
- `swift build` + `swift test` after each task
- Phase 1-2: unit tests against RFC test vectors
- Phase 3: loopback connection tests (in-memory + UDP loopback)
- Phase 4: full WebTransport session loopback (server + client)
- Phase 5: all existing server/client app tests pass unchanged
- Final: DMG build + deploy, verify real client↔server WebTransport session

## Specs Referenced
| RFC/Draft | Used For |
|-----------|----------|
| RFC 9000 | QUIC core: packets, frames, transport params, connection state |
| RFC 9001 | TLS 1.3 integration: key schedule, AEAD, header protection |
| RFC 9002 | Loss detection + congestion control |
| RFC 9114 | HTTP/3: framing, SETTINGS, control streams |
| RFC 9204 | QPACK static table indices (minimal impl) |
| RFC 9220 | Extended CONNECT for WebTransport |
| RFC 9221 | QUIC DATAGRAM frame |
| RFC 9297 | HTTP Datagrams + Capsule Protocol |
| RFC 8446 | TLS 1.3 handshake messages |
| draft-ietf-webtrans-http3-15 | WebTransport sessions, stream prefixes, capsules, SETTINGS |
| draft-ietf-quic-reliable-stream-reset-07 | RESET_STREAM_AT frame + transport parameter |

## Key Source Files to Reference During Implementation

### Existing Quiver files to study for API surface and behavior
| File | Purpose |
|------|---------|
| `Git/Server App/Vendor/Quiver/Sources/QUIC/QUICConfiguration.swift` | Configuration API to preserve |
| `Git/Server App/Vendor/Quiver/Sources/QUIC/QUICEndpoint.swift` | Endpoint API to preserve |
| `Git/Server App/Vendor/Quiver/Sources/QUIC/QUICConnection.swift` | Connection + Stream protocols to preserve |
| `Git/Server App/Vendor/Quiver/Sources/QUICCrypto/TLS/TLS13Provider.swift` | TLS provider protocol (simplified) |
| `Git/Server App/Vendor/Quiver/Sources/QUICCrypto/TLS/TLS13Handler.swift` | TLS handler to reimplement |
| `Git/Server App/Vendor/Quiver/Sources/HTTP3/WebTransport/` | WebTransport layer (3,684 lines) |
| `Git/Server App/Vendor/Quiver/Sources/HTTP3/HTTP3Settings.swift` | Settings to preserve |

### App files that import Quiver (need import updates only)
| File | Imports |
|------|---------|
| `Git/Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/PummelchenWebTransportService.swift` | HTTP3, QUIC, QUICCrypto |
| `Git/Server App/MCPummelchenModServer/Sources/MCPummelchenModServerCore/MCPummelchenModServerCore.swift` | QUICCrypto |
| `Git/Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/ClientWebTransportControlChannel.swift` | HTTP3, QUIC, QUICCrypto |
| `Git/Client App/MCPummelchenModClient/Sources/MCPummelchenModClientCore/PooledWebTransportChannel.swift` | HTTP3, QUIC, QUICCrypto |

### Shared contract layer (keep as-is, already draft-15 correct)
| File | Contents |
|------|----------|
| `Git/Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/WebTransportH3.swift` | `WebTransportH3Draft15` enum, `QUICVariableLengthInteger`, `WebTransportH3StreamPrefix`, `WebTransportH3Capsule`, `WebTransportH3Preflight` |
| `Git/Server App/MCPummelchenModShared/Sources/MCPummelchenModShared/APIModels.swift` | `WebTransportPreflightPayload`, `WebTransportControlRequest`, `WebTransportControlResponse` |

## Simplifications vs Quiver

| Feature Eliminated | Lines Saved | Reason |
|---|---|---|
| QPACK (Huffman, dynamic table) | ~2,436 | Only CONNECT pseudo-headers needed |
| 0-RTT / session resumption | ~2,500 | Not needed for control plane |
| ChaCha20-Poly1305 cipher | ~1,200 | Only AES-128-GCM needed |
| Connection migration | ~800 | Fixed 4-tuple |
| PMTU Discovery | ~600 | Fixed 1200-byte packets |
| ECN support | ~500 | Not needed |
| Pacing | ~400 | Low-volume JSON traffic |
| QLOG logging | ~1,200 | Use os_log / Logger |
| Version negotiation | ~300 | QUIC v1 only |
| Retry packets | ~400 | No address validation |
| General HTTP/3 (GET/POST) | ~4,000 | Only Extended CONNECT |
| Multi-cipher TLS | ~2,000 | Single cipher suite |
| X.509 via swift-certificates | ~3,000 | Security.framework instead |
| swift-nio dependency | ~1,300 | POSIX sockets + Dispatch |
