// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PummelchenServer",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "PummelchenServerCore",
            targets: ["PummelchenServerCore"]
        ),
        .executable(
            name: "pummelchen-server",
            targets: ["PummelchenServer"]
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
        .package(path: "../PummelchenShared"),
        .package(path: "../../Client App/PummelchenClient"),
        .package(path: "../Vendor/Quiver")
    ],
    targets: [
        .target(
            name: "PummelchenServerCore",
            dependencies: [
                .product(name: "PummelchenCore", package: "PummelchenShared"),
                .product(name: "HTTP3", package: "Quiver"),
                .product(name: "QUIC", package: "Quiver"),
                .product(name: "QUICCore", package: "Quiver"),
                .product(name: "QUICCrypto", package: "Quiver")
            ]
        ),
        .executableTarget(
            name: "PummelchenServer",
            dependencies: [
                "PummelchenServerCore",
                .product(name: "PummelchenCore", package: "PummelchenShared")
            ]
        ),
        .executableTarget(
            name: "PummelchenDuckDB",
            dependencies: [
                .product(name: "PummelchenCore", package: "PummelchenShared")
            ]
        ),
        .executableTarget(
            name: "PummelchenHeadlessSoak",
            dependencies: [
                .product(name: "PummelchenCore", package: "PummelchenShared"),
                .product(name: "PummelchenClientCore", package: "PummelchenClient")
            ]
        ),
        .executableTarget(
            name: "pummelchen-contracts",
            dependencies: [
                .product(name: "PummelchenCore", package: "PummelchenShared")
            ]
        ),
        .testTarget(
            name: "PummelchenServerTests",
            dependencies: [
                "PummelchenServerCore",
                .product(name: "PummelchenCore", package: "PummelchenShared"),
                .product(name: "PummelchenClientCore", package: "PummelchenClient")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
