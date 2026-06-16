// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PummelchenTransport",

    platforms: [
        .macOS(.v15),
    ],

    products: [
        .library(name: "PummelchenQuicCore", targets: ["PummelchenQuicCore"]),
        .library(name: "PummelchenQuicCrypto", targets: ["PummelchenQuicCrypto"]),
        .library(name: "PummelchenQuic", targets: ["PummelchenQuic"]),
        .library(name: "PummelchenHTTP3", targets: ["PummelchenHTTP3"]),
    ],

    targets: [
        // MARK: - Phase 1: Wire Primitives (Foundation only)
        .target(
            name: "PummelchenQuicCore",
            dependencies: [],
            path: "Sources/PummelchenQuicCore"
        ),

        // MARK: - Phase 2: TLS 1.3 + QUIC crypto (CryptoKit, Security.framework)
        .target(
            name: "PummelchenQuicCrypto",
            dependencies: ["PummelchenQuicCore"],
            path: "Sources/PummelchenQuicCrypto"
        ),

        // MARK: - Phase 3: QUIC transport (Dispatch, POSIX sockets)
        .target(
            name: "PummelchenQuic",
            dependencies: [
                "PummelchenQuicCore",
                "PummelchenQuicCrypto",
            ],
            path: "Sources/PummelchenQuic"
        ),

        // MARK: - Phase 4: HTTP/3 + WebTransport
        .target(
            name: "PummelchenHTTP3",
            dependencies: [
                "PummelchenQuicCore",
                "PummelchenQuicCrypto",
                "PummelchenQuic",
            ],
            path: "Sources/PummelchenHTTP3"
        ),

        // MARK: - Tests

        .testTarget(
            name: "PummelchenQuicCoreTests",
            dependencies: ["PummelchenQuicCore"],
            path: "Tests/PummelchenQuicCoreTests"
        ),

        .testTarget(
            name: "PummelchenQuicCryptoTests",
            dependencies: ["PummelchenQuicCrypto"],
            path: "Tests/PummelchenQuicCryptoTests"
        ),

        .testTarget(
            name: "PummelchenQuicTests",
            dependencies: ["PummelchenQuic"],
            path: "Tests/PummelchenQuicTests"
        ),

        .testTarget(
            name: "PummelchenHTTP3Tests",
            dependencies: ["PummelchenHTTP3"],
            path: "Tests/PummelchenHTTP3Tests"
        ),
    ]
)
