import Foundation

public enum WebTransportH3Error: Error, Equatable, CustomStringConvertible {
    case invalidVariableLengthInteger
    case truncatedVariableLengthInteger
    case variableLengthIntegerOverflow
    case invalidWebTransportSessionID(UInt64)
    case invalidStreamPrefix
    case missingRequiredSetting(String)
    case missingRequiredTransportParameter(String)
    case sessionEngineInactive(String)

    public var description: String {
        switch self {
        case .invalidVariableLengthInteger:
            return "invalid QUIC variable-length integer"
        case .truncatedVariableLengthInteger:
            return "truncated QUIC variable-length integer"
        case .variableLengthIntegerOverflow:
            return "QUIC variable-length integer exceeds 62 bits"
        case .invalidWebTransportSessionID(let sessionID):
            return "invalid WebTransport session ID \(sessionID); expected a client-initiated bidirectional QUIC stream ID"
        case .invalidStreamPrefix:
            return "invalid WebTransport stream prefix"
        case .missingRequiredSetting(let name):
            return "missing required HTTP/3 WebTransport setting \(name)"
        case .missingRequiredTransportParameter(let name):
            return "missing required QUIC WebTransport transport parameter \(name)"
        case .sessionEngineInactive(let message):
            return message
        }
    }
}

public enum QUICVariableLengthInteger {
    public static let maximumValue: UInt64 = 0x3fff_ffff_ffff_ffff

    public static func encode(_ value: UInt64) throws -> Data {
        guard value <= maximumValue else {
            throw WebTransportH3Error.variableLengthIntegerOverflow
        }
        if value < 64 {
            return Data([UInt8(value)])
        }
        if value < 16_384 {
            return Data([
                UInt8(0x40 | ((value >> 8) & 0x3f)),
                UInt8(value & 0xff)
            ])
        }
        if value < 1_073_741_824 {
            return Data([
                UInt8(0x80 | ((value >> 24) & 0x3f)),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff)
            ])
        }
        return Data([
            UInt8(0xc0 | ((value >> 56) & 0x3f)),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }

    public static func decode(_ data: Data, offset: inout Int) throws -> UInt64 {
        guard offset < data.count else {
            throw WebTransportH3Error.truncatedVariableLengthInteger
        }
        let first = data[offset]
        let length = 1 << Int(first >> 6)
        guard data.count - offset >= length else {
            throw WebTransportH3Error.truncatedVariableLengthInteger
        }

        var value = UInt64(first & 0x3f)
        offset += 1
        for _ in 1..<length {
            value = (value << 8) | UInt64(data[offset])
            offset += 1
        }
        guard value <= maximumValue else {
            throw WebTransportH3Error.variableLengthIntegerOverflow
        }
        return value
    }
}

public enum WebTransportH3Draft15 {
    public static let upgradeToken = "webtransport-h3"

    public enum Setting {
        public static let enableConnectProtocol: UInt64 = 0x08
        public static let h3Datagram: UInt64 = 0x33
        public static let wtInitialMaxData: UInt64 = 0x2b61
        public static let wtInitialMaxStreamsUni: UInt64 = 0x2b64
        public static let wtInitialMaxStreamsBidi: UInt64 = 0x2b65
        public static let wtEnabled: UInt64 = 0x2c7c_f000
    }

    public enum Stream {
        public static let bidirectionalSignal: UInt64 = 0x41
        public static let unidirectionalType: UInt64 = 0x54
    }

    public enum Capsule {
        public static let wtMaxStreamsBidi: UInt64 = 0x190b_4d3f
        public static let wtMaxStreamsUni: UInt64 = 0x190b_4d40
    }

    public static func isClientInitiatedBidirectionalStreamID(_ streamID: UInt64) -> Bool {
        streamID % 4 == 0
    }
}

public struct WebTransportH3Preflight: Equatable, Sendable {
    public let serverHTTP3Settings: [UInt64: UInt64]
    public let maxDatagramFrameSize: UInt64?
    public let resetStreamAtEnabled: Bool
    public let sessionEngineActive: Bool
    public let dedicatedUDPPort: Int
    public let behindNginx: Bool

    public init(
        serverHTTP3Settings: [UInt64: UInt64],
        maxDatagramFrameSize: UInt64?,
        resetStreamAtEnabled: Bool,
        sessionEngineActive: Bool = false,
        dedicatedUDPPort: Int = 7443,
        behindNginx: Bool = false
    ) {
        self.serverHTTP3Settings = serverHTTP3Settings
        self.maxDatagramFrameSize = maxDatagramFrameSize
        self.resetStreamAtEnabled = resetStreamAtEnabled
        self.sessionEngineActive = sessionEngineActive
        self.dedicatedUDPPort = dedicatedUDPPort
        self.behindNginx = behindNginx
    }

    public func validateServerSupport() throws {
        guard sessionEngineActive else {
            throw WebTransportH3Error.sessionEngineInactive("Swift WebTransport session engine is not active on dedicated UDP port \(dedicatedUDPPort)")
        }
        guard !behindNginx else {
            throw WebTransportH3Error.sessionEngineInactive("WebTransport must use the Swift server app dedicated UDP port, not the nginx HTTP/3 edge")
        }
        try requireSetting(WebTransportH3Draft15.Setting.wtEnabled, name: "SETTINGS_WT_ENABLED", greaterThanZero: true)
        try requireSetting(WebTransportH3Draft15.Setting.enableConnectProtocol, name: "SETTINGS_ENABLE_CONNECT_PROTOCOL")
        try requireSetting(WebTransportH3Draft15.Setting.h3Datagram, name: "SETTINGS_H3_DATAGRAM")
        guard let maxDatagramFrameSize, maxDatagramFrameSize > 0 else {
            throw WebTransportH3Error.missingRequiredTransportParameter("max_datagram_frame_size")
        }
        guard resetStreamAtEnabled else {
            throw WebTransportH3Error.missingRequiredTransportParameter("reset_stream_at")
        }
    }

    public func unsupportedReason() -> String? {
        do {
            try validateServerSupport()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private func requireSetting(_ id: UInt64, name: String, greaterThanZero: Bool = false) throws {
        guard let value = serverHTTP3Settings[id], greaterThanZero ? value > 0 : value == 1 else {
            throw WebTransportH3Error.missingRequiredSetting(name)
        }
    }
}

public struct WebTransportH3StreamPrefix: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bidirectional
        case unidirectional
    }

    public let kind: Kind
    public let sessionID: UInt64

    public init(kind: Kind, sessionID: UInt64) throws {
        guard WebTransportH3Draft15.isClientInitiatedBidirectionalStreamID(sessionID) else {
            throw WebTransportH3Error.invalidWebTransportSessionID(sessionID)
        }
        self.kind = kind
        self.sessionID = sessionID
    }

    public func encode() throws -> Data {
        var data = Data()
        switch kind {
        case .bidirectional:
            data.append(try QUICVariableLengthInteger.encode(WebTransportH3Draft15.Stream.bidirectionalSignal))
        case .unidirectional:
            data.append(try QUICVariableLengthInteger.encode(WebTransportH3Draft15.Stream.unidirectionalType))
        }
        data.append(try QUICVariableLengthInteger.encode(sessionID))
        return data
    }

    public static func decode(_ data: Data, expectedKind: Kind, consumedBytes: inout Int) throws -> WebTransportH3StreamPrefix {
        var offset = consumedBytes
        let marker = try QUICVariableLengthInteger.decode(data, offset: &offset)
        switch (expectedKind, marker) {
        case (.bidirectional, WebTransportH3Draft15.Stream.bidirectionalSignal),
             (.unidirectional, WebTransportH3Draft15.Stream.unidirectionalType):
            break
        default:
            throw WebTransportH3Error.invalidStreamPrefix
        }
        let sessionID = try QUICVariableLengthInteger.decode(data, offset: &offset)
        consumedBytes = offset
        return try WebTransportH3StreamPrefix(kind: expectedKind, sessionID: sessionID)
    }
}

public struct WebTransportH3Capsule: Equatable, Sendable {
    public let type: UInt64
    public let payload: Data

    public init(type: UInt64, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public func encode() throws -> Data {
        var data = Data()
        data.append(try QUICVariableLengthInteger.encode(type))
        data.append(try QUICVariableLengthInteger.encode(UInt64(payload.count)))
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data, offset: inout Int) throws -> WebTransportH3Capsule {
        let type = try QUICVariableLengthInteger.decode(data, offset: &offset)
        let length = try QUICVariableLengthInteger.decode(data, offset: &offset)
        guard length <= UInt64(data.count - offset) else {
            throw WebTransportH3Error.truncatedVariableLengthInteger
        }
        let end = offset + Int(length)
        let payload = data.subdata(in: offset..<end)
        offset = end
        return WebTransportH3Capsule(type: type, payload: payload)
    }
}
