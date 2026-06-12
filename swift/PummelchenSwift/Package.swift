// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PummelchenSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PummelchenCore",
            targets: ["PummelchenCore"]
        ),
        .executable(
            name: "pummelchen-contracts",
            targets: ["pummelchen-contracts"]
        ),
        .executable(
            name: "pummelchen-duckdb",
            targets: ["PummelchenDuckDB"]
        ),
        .executable(
            name: "pummelchen-server",
            targets: ["PummelchenServer"]
        )
    ],
    targets: [
        .target(
            name: "PummelchenCore"
        ),
        .target(
            name: "PummelchenServerCore",
            dependencies: ["PummelchenCore"]
        ),
        .executableTarget(
            name: "pummelchen-contracts",
            dependencies: ["PummelchenCore"]
        ),
        .executableTarget(
            name: "PummelchenDuckDB",
            dependencies: ["PummelchenCore"]
        ),
        .executableTarget(
            name: "PummelchenServer",
            dependencies: ["PummelchenServerCore"]
        ),
        .testTarget(
            name: "PummelchenCoreTests",
            dependencies: [
                "PummelchenCore",
                "PummelchenServerCore"
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
