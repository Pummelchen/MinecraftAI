// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PummelchenShared",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PummelchenCore",
            targets: ["PummelchenCore"]
        )
    ],
    targets: [
        .target(
            name: "PummelchenCore"
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
