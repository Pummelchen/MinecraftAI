/// HTTP/3 Framing and Minimal QPACK (RFC 9114, RFC 9204)
///
/// HTTP/3 frame encoding/decoding for QUIC transport.
/// Minimal QPACK: static table only, no Huffman, no dynamic table.

import Foundation
import PummelchenQuicCore

// MARK: - HTTP/3 Frame Types

/// HTTP/3 frame type identifiers (RFC 9114 §7.2).
public enum HTTP3FrameType: UInt64, Sendable {
    case data = 0x00
    case headers = 0x01
    case cancelPush = 0x03
    case settings = 0x04
    case pushPromise = 0x05
    case goaway = 0x07
    case maxPushID = 0x0d
}

// MARK: - HTTP/3 Unidirectional Stream Types

/// HTTP/3 unidirectional stream type identifiers (RFC 9114 §6.2).
public enum HTTP3UniStreamType: UInt64, Sendable {
    case control = 0x00
    case push = 0x01
    case qpackEncoder = 0x02
    case qpackDecoder = 0x03
}

// MARK: - HTTP/3 Settings

/// HTTP/3 setting identifiers.
public enum HTTP3SettingID: UInt64, Sendable {
    case maxFieldSectionSize = 0x06
    case webTransportEnabled = 0x2c7cf000 // draft-ietf-webtrans-http3-15 §9.2
    case enableConnectProtocol = 0x08     // RFC 9220
}

/// An HTTP/3 setting (identifier + value).
public struct HTTP3Setting: Sendable, Hashable {
    public let id: UInt64
    public let value: UInt64

    public init(id: UInt64, value: UInt64) {
        self.id = id
        self.value = value
    }

    public init(id: HTTP3SettingID, value: UInt64) {
        self.id = id.rawValue
        self.value = value
    }
}

// MARK: - HTTP/3 Frame

/// An HTTP/3 frame (type + length-prefixed payload).
public struct HTTP3Frame: Sendable {
    public let type: UInt64
    public let payload: Data

    public init(type: UInt64, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public init(type: HTTP3FrameType, payload: Data) {
        self.type = type.rawValue
        self.payload = payload
    }

    /// Encode with varint type + varint length + payload.
    public func encode() -> Data {
        var result = Data()
        result.append(contentsOf: Varint.encode(type))
        result.append(contentsOf: Varint.encode(UInt64(payload.count)))
        result.append(payload)
        return result
    }

    /// Decode a frame from a reader.
    public static func decode(from data: Data, offset: inout Int) -> HTTP3Frame? {
        guard let (frameType, typeLen) = Varint.decode(data, offset: offset) else {
            return nil
        }
        offset += typeLen

        guard let (payloadLen, lenLen) = Varint.decode(data, offset: offset) else {
            return nil
        }
        offset += lenLen

        let end = offset + Int(payloadLen)
        guard end <= data.count else { return nil }

        let payload = Data(data[offset..<end])
        offset = end
        return HTTP3Frame(type: frameType, payload: payload)
    }
}

// MARK: - SETTINGS Frame

/// HTTP/3 SETTINGS frame (RFC 9114 §7.2.4).
public struct HTTP3SettingsFrame: Sendable {
    public var settings: [HTTP3Setting]

    public init(settings: [HTTP3Setting] = []) {
        self.settings = settings
    }

    /// Encode the SETTINGS payload.
    public func encodePayload() -> Data {
        var result = Data()
        for setting in settings {
            result.append(contentsOf: Varint.encode(setting.id))
            result.append(contentsOf: Varint.encode(setting.value))
        }
        return result
    }

    /// Decode SETTINGS payload.
    public static func decodePayload(_ data: Data) -> HTTP3SettingsFrame {
        var settings: [HTTP3Setting] = []
        var offset = 0
        while offset < data.count {
            guard let (id, idLen) = Varint.decode(data, offset: offset),
                  let (value, valLen) = Varint.decode(data, offset: offset + idLen) else {
                break
            }
            settings.append(HTTP3Setting(id: id, value: value))
            offset += idLen + valLen
        }
        return HTTP3SettingsFrame(settings: settings)
    }

    /// Look up a setting value.
    public func value(for id: HTTP3SettingID) -> UInt64? {
        settings.first(where: { $0.id == id.rawValue })?.value
    }
}

// MARK: - HEADERS Frame (QPACK)

/// Minimal QPACK header encoding (static table only, no Huffman).
public enum QPACK {
    /// A decoded HTTP header field.
    public struct HeaderField: Sendable, Hashable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Encode headers into a QPACK header block (no compression, literal only).
    public static func encodeHeaders(_ headers: [HeaderField]) -> Data {
        var result = Data()

        // Required Insert Count = 0 (no dynamic table references)
        result.append(contentsOf: Varint.encode(0))
        // Delta Base = 0
        result.append(0x00)

        for header in headers {
            // Literal header field without name reference (0x20 prefix)
            // Actually: use literal with name (never indexed) = 0x10 prefix
            // Format: 0001 N H (name length) (name) (value length) (value)

            let nameBytes = Data(header.name.utf8)
            let valueBytes = Data(header.value.utf8)

            // Literal header field without name reference
            // 0b0001_0000 | N=0 | H=0 (not Huffman encoded)
            let prefix: UInt8 = 0x10 // Never indexed, not Huffman
            result.append(prefix)

            // Name length (varint) + name
            result.append(contentsOf: Varint.encode(UInt64(nameBytes.count)))
            result.append(nameBytes)

            // Value length (varint) + value
            result.append(contentsOf: Varint.encode(UInt64(valueBytes.count)))
            result.append(valueBytes)
        }

        return result
    }

    /// Decode headers from a QPACK header block (handles literal fields only).
    public static func decodeHeaders(_ data: Data) throws -> [HeaderField] {
        var headers: [HeaderField] = []
        var offset = 0

        // Read Required Insert Count
        guard let (_, ricLen) = Varint.decode(data, offset: offset) else {
            throw HTTP3Error.malformedHeaders
        }
        offset += ricLen

        // Read Delta Base
        guard offset < data.count else { throw HTTP3Error.malformedHeaders }
        offset += 1 // Delta Base (1 byte for our simple case)

        while offset < data.count {
            let byte = data[data.startIndex + offset]

            if byte & 0x80 != 0 {
                // Indexed field (static table reference)
                // TODO: Look up in static table
                throw HTTP3Error.unsupportedQPACKFeature("indexed field")
            } else if byte & 0x40 != 0 {
                // Literal with name reference
                throw HTTP3Error.unsupportedQPACKFeature("literal with name reference")
            } else if byte & 0x20 != 0 {
                // Literal with post-base name reference
                throw HTTP3Error.unsupportedQPACKFeature("post-base reference")
            } else {
                // Literal without name reference
                offset += 1

                let isHuffman = (byte & 0x08) != 0

                // Name
                guard let (nameLen, nameLenSize) = Varint.decode(data, offset: offset) else {
                    throw HTTP3Error.malformedHeaders
                }
                offset += nameLenSize
                guard offset + Int(nameLen) <= data.count else { throw HTTP3Error.malformedHeaders }
                let nameData = Data(data[data.startIndex + offset..<data.startIndex + offset + Int(nameLen)])
                offset += Int(nameLen)

                // Value
                guard let (valueLen, valueLenSize) = Varint.decode(data, offset: offset) else {
                    throw HTTP3Error.malformedHeaders
                }
                offset += valueLenSize
                guard offset + Int(valueLen) <= data.count else { throw HTTP3Error.malformedHeaders }
                let valueData = Data(data[data.startIndex + offset..<data.startIndex + offset + Int(valueLen)])
                offset += Int(valueLen)

                let name: String
                let value: String
                if isHuffman {
                    // TODO: Huffman decoding
                    name = String(data: nameData, encoding: .utf8) ?? ""
                    value = String(data: valueData, encoding: .utf8) ?? ""
                } else {
                    name = String(data: nameData, encoding: .utf8) ?? ""
                    value = String(data: valueData, encoding: .utf8) ?? ""
                }

                headers.append(HeaderField(name: name, value: value))
            }
        }

        return headers
    }
}

// MARK: - HTTP/3 Errors

/// HTTP/3 protocol errors.
public enum HTTP3Error: Error, Sendable {
    case malformedFrame
    case malformedHeaders
    case unsupportedQPACKFeature(String)
    case unexpectedStreamType(UInt64)
    case settingsNotReceived
    case webTransportNotEnabled
    case closedCriticalStream
}
