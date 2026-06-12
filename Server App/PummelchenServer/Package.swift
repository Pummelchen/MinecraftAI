// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PummelchenServer",
    platforms: [
        .macOS(.v14)
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
            name: "pummelchen-contracts",
            targets: ["pummelchen-contracts"]
        )
    ],
    dependencies: [
        .package(path: "../PummelchenShared"),
        .package(path: "../../Client App/PummelchenClient")
    ],
    targets: [
        .target(
            name: "PummelchenServerCore",
            dependencies: [
                .product(name: "PummelchenCore", package: "PummelchenShared")
            ]
        ),
        .executableTarget(
            name: "PummelchenServer",
            dependencies: ["PummelchenServerCore"]
        ),
        .executableTarget(
            name: "PummelchenDuckDB",
            dependencies: [
                .product(name: "PummelchenCore", package: "PummelchenShared")
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
