// swift-tools-version: 6.2

import PackageDescription

var products: [Product] = [
    .library(
        name: "MCPummelchenModClientCore",
        targets: ["MCPummelchenModClientCore"]
    ),
    .executable(
        name: "pummelchen-client-sync",
        targets: ["MCPummelchenModClientSync"]
    )
]

var targets: [Target] = [
    .target(
        name: "MCPummelchenModClientCore",
        dependencies: [
            .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared"),
            .product(name: "PummelchenHTTP3", package: "PummelchenTransport"),
            .product(name: "PummelchenQuic", package: "PummelchenTransport"),
            .product(name: "PummelchenQuicCore", package: "PummelchenTransport"),
            .product(name: "PummelchenQuicCrypto", package: "PummelchenTransport")
        ]
    ),
    .executableTarget(
        name: "MCPummelchenModClientSync",
        dependencies: ["MCPummelchenModClientCore"]
    ),
    .testTarget(
        name: "MCPummelchenModClientTests",
        dependencies: [
            "MCPummelchenModClientCore",
            .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared")
        ]
    )
]

#if os(macOS)
products.append(
    .executable(
        name: "MCPummelchenModClient",
        targets: ["MCPummelchenModClient"]
    )
)
targets.append(
    .executableTarget(
        name: "MCPummelchenModClient",
        dependencies: ["MCPummelchenModClientCore"]
    )
)
#endif

let package = Package(
    name: "MCPummelchenModClient",
    platforms: [
        .macOS("26.0")
    ],
    products: products,
    dependencies: [
        .package(path: "../../Server App/MCPummelchenModShared"),
        .package(path: "../../Server App/Vendor/PummelchenTransport")
    ],
    targets: targets
)
