/// HTTP/3 Connection (RFC 9114)
///
/// Manages HTTP/3 unidirectional streams (control, QPACK) and
/// bidirectional request/response streams over QUIC.

import Foundation
import PummelchenQuicCore
import PummelchenQuic

// MARK: - HTTP/3 Connection

/// An HTTP/3 connection over QUIC.
public final class HTTP3Connection: @unchecked Sendable {
    /// Our local settings
    public let localSettings: HTTP3SettingsFrame

    /// Peer's settings (populated after receiving SETTINGS)
    public private(set) var peerSettings: HTTP3SettingsFrame?

    /// Whether peer has acknowledged our SETTINGS
    public private(set) var peerSettingsReceived: Bool = false

    /// Control stream buffers
    private var controlStreamBuffer = Data()

    /// Whether the connection is established (SETTINGS exchanged)
    public var isReady: Bool { peerSettings != nil }

    /// Whether WebTransport is enabled by both sides
    public var isWebTransportEnabled: Bool {
        let localWT = localSettings.value(for: .webTransportEnabled) ?? 0
        let peerWT = peerSettings?.value(for: .webTransportEnabled) ?? 0
        return localWT != 0 && peerWT != 0
    }

    public init(localSettings: HTTP3SettingsFrame) {
        self.localSettings = localSettings
    }

    // MARK: - Control Stream

    /// Build the control stream initial data (stream type + SETTINGS frame).
    public func buildControlStreamData() -> Data {
        var data = Data()

        // Stream type: control (0x00)
        data.append(contentsOf: Varint.encode(HTTP3UniStreamType.control.rawValue))

        // SETTINGS frame
        let settingsPayload = localSettings.encodePayload()
        let settingsFrame = HTTP3Frame(type: .settings, payload: settingsPayload)
        data.append(settingsFrame.encode())

        return data
    }

    /// Process incoming control stream data.
    public func processControlStreamData(_ data: Data) throws {
        controlStreamBuffer.append(data)
        var offset = 0

        // First frame should be SETTINGS
        if peerSettings == nil {
            guard let frame = HTTP3Frame.decode(from: controlStreamBuffer, offset: &offset) else {
                return // Need more data
            }

            guard frame.type == HTTP3FrameType.settings.rawValue else {
                throw HTTP3Error.settingsNotReceived
            }

            peerSettings = HTTP3SettingsFrame.decodePayload(frame.payload)
            peerSettingsReceived = true
            controlStreamBuffer.removeFirst(offset)
        }
    }

    // MARK: - Bidirectional Streams

    /// Build a HEADERS frame for an HTTP request/response.
    public func buildHeadersFrame(headers: [QPACK.HeaderField]) -> Data {
        let encoded = QPACK.encodeHeaders(headers)
        let frame = HTTP3Frame(type: .headers, payload: encoded)
        return frame.encode()
    }

    /// Build a DATA frame.
    public func buildDataFrame(data: Data) -> Data {
        let frame = HTTP3Frame(type: .data, payload: data)
        return frame.encode()
    }

    /// Decode frames from a bidirectional stream.
    public func decodeFrames(from data: Data) throws -> [HTTP3Frame] {
        var frames: [HTTP3Frame] = []
        var offset = 0
        while offset < data.count {
            guard let frame = HTTP3Frame.decode(from: data, offset: &offset) else {
                break
            }
            frames.append(frame)
        }
        return frames
    }
}

// MARK: - HTTP/3 Server

/// HTTP/3 server that accepts incoming connections and requests.
public final class HTTP3Server: @unchecked Sendable {
    /// Server configuration
    public let settings: HTTP3SettingsFrame

    /// Called when a new bidirectional stream request arrives
    public var onRequest: (([QPACK.HeaderField], HTTP3RequestContext) -> Void)?

    public init(settings: HTTP3SettingsFrame = HTTP3Server.defaultSettings()) {
        self.settings = settings
    }

    /// Default server settings with WebTransport enabled.
    public static func defaultSettings() -> HTTP3SettingsFrame {
        HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .webTransportEnabled, value: 1),
            HTTP3Setting(id: .enableConnectProtocol, value: 1),
            HTTP3Setting(id: .maxFieldSectionSize, value: 65536),
        ])
    }
}

// MARK: - HTTP/3 Client

/// HTTP/3 client for making requests.
public final class HTTP3Client: @unchecked Sendable {
    /// Client configuration
    public let settings: HTTP3SettingsFrame

    public init(settings: HTTP3SettingsFrame = HTTP3Client.defaultSettings()) {
        self.settings = settings
    }

    /// Default client settings with WebTransport enabled.
    public static func defaultSettings() -> HTTP3SettingsFrame {
        HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .webTransportEnabled, value: 1),
            HTTP3Setting(id: .enableConnectProtocol, value: 1),
        ])
    }
}

// MARK: - Request Context

/// Context for an HTTP/3 request.
public struct HTTP3RequestContext: Sendable {
    /// Stream ID of the request
    public let streamID: UInt64

    /// The parsed request headers
    public let headers: [QPACK.HeaderField]

    public init(streamID: UInt64, headers: [QPACK.HeaderField]) {
        self.streamID = streamID
        self.headers = headers
    }

    /// Get a header value by name.
    public func header(_ name: String) -> String? {
        headers.first(where: { $0.name == name })?.value
    }
}
