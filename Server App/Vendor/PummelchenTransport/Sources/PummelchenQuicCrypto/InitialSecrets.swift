/// QUIC Initial Secrets (RFC 9001 Section 5.2)
///
/// Derives client/server initial secrets from the destination connection ID.
/// Uses the QUIC v1 salt: 0x38762cf7f55934b34d179ae6a4c80cadccbb7f0a

import Foundation
import CryptoKit
import PummelchenQuicCore

/// QUIC v1 initial salt (RFC 9001 §5.2)
private let initialSalt = Data([
    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
    0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
    0xcc, 0xbb, 0x7f, 0x0a
])

/// Derives initial encryption keys from the destination connection ID.
public enum InitialSecrets {
    /// Derives the initial secret from a DCID.
    public static func initialSecret(from dcid: ConnectionID) -> Data {
        return QUICHKDF.extract(salt: initialSalt, inputKeyingMaterial: dcid.bytes)
    }

    /// Derives client initial keys.
    public static func clientInitialKeys(from dcid: ConnectionID) -> EncryptionKeys {
        let initialSecret = self.initialSecret(from: dcid)
        let clientSecret = QUICHKDF.expandLabel(
            secret: initialSecret,
            label: "client in",
            context: Data(),
            length: 32
        )
        return EncryptionKeys.fromTrafficSecret(clientSecret)
    }

    /// Derives server initial keys.
    public static func serverInitialKeys(from dcid: ConnectionID) -> EncryptionKeys {
        let initialSecret = self.initialSecret(from: dcid)
        let serverSecret = QUICHKDF.expandLabel(
            secret: initialSecret,
            label: "server in",
            context: Data(),
            length: 32
        )
        return EncryptionKeys.fromTrafficSecret(serverSecret)
    }
}
