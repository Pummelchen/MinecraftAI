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
            .product(name: "MCPummelchenModShared", package: "MCPummelchenModShared")
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
        .package(path: "../../Server App/MCPummelchenModShared")
    ],
    targets: targets
)
