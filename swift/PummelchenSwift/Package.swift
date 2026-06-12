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
        )
    ],
    targets: [
        .target(
            name: "PummelchenCore"
        ),
        .executableTarget(
            name: "pummelchen-contracts",
            dependencies: ["PummelchenCore"]
        ),
        .executableTarget(
            name: "PummelchenDuckDB",
            dependencies: ["PummelchenCore"]
        ),
        .testTarget(
            name: "PummelchenCoreTests",
            dependencies: ["PummelchenCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
