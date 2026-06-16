// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MCPummelchenModServer",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "MCPummelchenModServerCore",
            targets: ["MCPummelchenModServerCore"]
        ),
        .executable(
            name: "MCPummelchenModServer",
            targets: ["MCPummelchenModServer"]
        ),
        .executable(
            name: "pummelchen-duckdb",
            targets: ["PummelchenDuckDB"]
        ),
        .executable(
            name: "pummelchen-headless-soak",
            targets: ["PummelchenHeadlessSoak"]
        ),
        .executable(
            name: "pummelchen-contracts",
            targets: ["pummelchen-contracts"]
        )
    ],
    dependencies: [
        .package(path: "../MCPummelchenModShared"),
        .package(path: "../../Client App/MCPummelchenModClient"),
        .package(path: "../Vendor/PummelchenTransport")
    ],
    targets: [
        .target(
            name: "MCPummelchenModServerCore",
            dependencies: [
                .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared"),
                .product(name: "PummelchenHTTP3", package: "PummelchenTransport"),
                .product(name: "PummelchenQuic", package: "PummelchenTransport"),
                .product(name: "PummelchenQuicCore", package: "PummelchenTransport"),
                .product(name: "PummelchenQuicCrypto", package: "PummelchenTransport")
            ]
        ),
        .executableTarget(
            name: "MCPummelchenModServer",
            dependencies: [
                "MCPummelchenModServerCore",
                .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared")
            ]
        ),
        .executableTarget(
            name: "PummelchenDuckDB",
            dependencies: [
                .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared")
            ]
        ),
        .executableTarget(
            name: "PummelchenHeadlessSoak",
            dependencies: [
                .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared"),
                .product(name: "MCPummelchenModClientCore", package: "MCPummelchenModClient")
            ]
        ),
        .executableTarget(
            name: "pummelchen-contracts",
            dependencies: [
                .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared")
            ]
        ),
        .testTarget(
            name: "MCPummelchenModServerTests",
            dependencies: [
                "MCPummelchenModServerCore",
                .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared"),
                .product(name: "MCPummelchenModClientCore", package: "MCPummelchenModClient")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
