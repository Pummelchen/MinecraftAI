/// QUIC Transport Parameters (RFC 9000 Section 18)
///
/// Exchanged during TLS handshake via quic_transport_parameters extension (0x0039).
/// Includes max_datagram_frame_size (0x20) and reset_stream_at (0x17f7586d2cb571).

import Foundation

/// QUIC Transport Parameters
public struct TransportParameters: Sendable, Hashable {
    public var originalDestinationConnectionID: ConnectionID?
    public var maxIdleTimeout: UInt64
    public var statelessResetToken: Data?
    public var maxUDPPayloadSize: UInt64
    public var initialMaxData: UInt64
    public var initialMaxStreamDataBidiLocal: UInt64
    public var initialMaxStreamDataBidiRemote: UInt64
    public var initialMaxStreamDataUni: UInt64
    public var initialMaxStreamsBidi: UInt64
    public var initialMaxStreamsUni: UInt64
    public var ackDelayExponent: UInt64
    public var maxAckDelay: UInt64
    public var disableActiveMigration: Bool
    public var activeConnectionIDLimit: UInt64
    public var initialSourceConnectionID: ConnectionID?
    public var retrySourceConnectionID: ConnectionID?
    public var maxDatagramFrameSize: UInt64?
    public var resetStreamAtSupport: Bool

    public init() {
        self.maxIdleTimeout = 30_000
        self.maxUDPPayloadSize = 65527
        self.initialMaxData = 10_000_000
        self.initialMaxStreamDataBidiLocal = 1_000_000
        self.initialMaxStreamDataBidiRemote = 1_000_000
        self.initialMaxStreamDataUni = 1_000_000
        self.initialMaxStreamsBidi = 100
        self.initialMaxStreamsUni = 100
        self.ackDelayExponent = 3
        self.maxAckDelay = 25
        self.disableActiveMigration = false
        self.activeConnectionIDLimit = 2
        self.maxDatagramFrameSize = nil
        self.resetStreamAtSupport = false
    }

    // MARK: - Transport Parameter IDs (RFC 9000 §18.2)

    private enum ParamID {
        static let originalDestinationConnectionID: UInt64 = 0x00
        static let maxIdleTimeout: UInt64 = 0x01
        static let statelessResetToken: UInt64 = 0x02
        static let maxUDPPayloadSize: UInt64 = 0x03
        static let initialMaxData: UInt64 = 0x04
        static let initialMaxStreamDataBidiLocal: UInt64 = 0x05
        static let initialMaxStreamDataBidiRemote: UInt64 = 0x06
        static let initialMaxStreamDataUni: UInt64 = 0x07
        static let initialMaxStreamsBidi: UInt64 = 0x08
        static let initialMaxStreamsUni: UInt64 = 0x09
        static let ackDelayExponent: UInt64 = 0x0a
        static let maxAckDelay: UInt64 = 0x0b
        static let disableActiveMigration: UInt64 = 0x0c
        static let activeConnectionIDLimit: UInt64 = 0x0e
        static let initialSourceConnectionID: UInt64 = 0x0f
        static let retrySourceConnectionID: UInt64 = 0x10
        // RFC 9221
        static let maxDatagramFrameSize: UInt64 = 0x20
        // draft-ietf-quic-reliable-stream-reset-07
        static let resetStreamAt: UInt64 = 0x17f7586d2cb571
    }

    // MARK: - Encode

    /// Encodes transport parameters to wire format.
    public func encode() -> Data {
        var data = Data()

        func writeParam(_ id: UInt64, _ value: Data) {
            Varint(id).encode(to: &data)
            Varint(UInt64(value.count)).encode(to: &data)
            data.append(value)
        }

        func writeVarintParam(_ id: UInt64, _ value: UInt64) {
            Varint(id).encode(to: &data)
            let encoded = Varint(value).encode()
            Varint(UInt64(encoded.count)).encode(to: &data)
            data.append(encoded)
        }

        func writeEmptyParam(_ id: UInt64) {
            Varint(id).encode(to: &data)
            Varint(0).encode(to: &data)
        }

        if let cid = originalDestinationConnectionID {
            writeParam(ParamID.originalDestinationConnectionID, cid.bytes)
        }
        if maxIdleTimeout != 0 {
            writeVarintParam(ParamID.maxIdleTimeout, maxIdleTimeout)
        }
        if let token = statelessResetToken {
            writeParam(ParamID.statelessResetToken, token)
        }
        if maxUDPPayloadSize != 65527 {
            writeVarintParam(ParamID.maxUDPPayloadSize, maxUDPPayloadSize)
        }
        writeVarintParam(ParamID.initialMaxData, initialMaxData)
        writeVarintParam(ParamID.initialMaxStreamDataBidiLocal, initialMaxStreamDataBidiLocal)
        writeVarintParam(ParamID.initialMaxStreamDataBidiRemote, initialMaxStreamDataBidiRemote)
        writeVarintParam(ParamID.initialMaxStreamDataUni, initialMaxStreamDataUni)
        writeVarintParam(ParamID.initialMaxStreamsBidi, initialMaxStreamsBidi)
        writeVarintParam(ParamID.initialMaxStreamsUni, initialMaxStreamsUni)
        if ackDelayExponent != 3 {
            writeVarintParam(ParamID.ackDelayExponent, ackDelayExponent)
        }
        if maxAckDelay != 25 {
            writeVarintParam(ParamID.maxAckDelay, maxAckDelay)
        }
        if disableActiveMigration {
            writeEmptyParam(ParamID.disableActiveMigration)
        }
        if activeConnectionIDLimit != 2 {
            writeVarintParam(ParamID.activeConnectionIDLimit, activeConnectionIDLimit)
        }
        if let cid = initialSourceConnectionID {
            writeParam(ParamID.initialSourceConnectionID, cid.bytes)
        }
        if let cid = retrySourceConnectionID {
            writeParam(ParamID.retrySourceConnectionID, cid.bytes)
        }
        if let size = maxDatagramFrameSize {
            writeVarintParam(ParamID.maxDatagramFrameSize, size)
        }
        if resetStreamAtSupport {
            writeEmptyParam(ParamID.resetStreamAt)
        }

        return data
    }

    // MARK: - Decode

    /// Decodes transport parameters from wire format.
    public static func decode(from data: Data) throws -> TransportParameters {
        var params = TransportParameters()
        var reader = FrameReader(data)

        while !reader.isEmpty {
            let id = try reader.readVarint().value
            let length = Int(try reader.readVarint().value)
            let value = length > 0 ? try reader.readBytes(length) : Data()

            switch id {
            case ParamID.originalDestinationConnectionID:
                params.originalDestinationConnectionID = ConnectionID(value)
            case ParamID.maxIdleTimeout:
                params.maxIdleTimeout = try Self.decodeVarintValue(value)
            case ParamID.statelessResetToken:
                params.statelessResetToken = value
            case ParamID.maxUDPPayloadSize:
                params.maxUDPPayloadSize = try Self.decodeVarintValue(value)
            case ParamID.initialMaxData:
                params.initialMaxData = try Self.decodeVarintValue(value)
            case ParamID.initialMaxStreamDataBidiLocal:
                params.initialMaxStreamDataBidiLocal = try Self.decodeVarintValue(value)
            case ParamID.initialMaxStreamDataBidiRemote:
                params.initialMaxStreamDataBidiRemote = try Self.decodeVarintValue(value)
            case ParamID.initialMaxStreamDataUni:
                params.initialMaxStreamDataUni = try Self.decodeVarintValue(value)
            case ParamID.initialMaxStreamsBidi:
                params.initialMaxStreamsBidi = try Self.decodeVarintValue(value)
            case ParamID.initialMaxStreamsUni:
                params.initialMaxStreamsUni = try Self.decodeVarintValue(value)
            case ParamID.ackDelayExponent:
                params.ackDelayExponent = try Self.decodeVarintValue(value)
            case ParamID.maxAckDelay:
                params.maxAckDelay = try Self.decodeVarintValue(value)
            case ParamID.disableActiveMigration:
                params.disableActiveMigration = true
            case ParamID.activeConnectionIDLimit:
                params.activeConnectionIDLimit = try Self.decodeVarintValue(value)
            case ParamID.initialSourceConnectionID:
                params.initialSourceConnectionID = ConnectionID(value)
            case ParamID.retrySourceConnectionID:
                params.retrySourceConnectionID = ConnectionID(value)
            case ParamID.maxDatagramFrameSize:
                params.maxDatagramFrameSize = try Self.decodeVarintValue(value)
            case ParamID.resetStreamAt:
                params.resetStreamAtSupport = true
            default:
                // Unknown parameter — skip (RFC 9000 §18.1)
                break
            }
        }

        return params
    }

    private static func decodeVarintValue(_ data: Data) throws -> UInt64 {
        guard !data.isEmpty else { return 0 }
        let (v, _) = try Varint.decode(from: data)
        return v.value
    }
}
