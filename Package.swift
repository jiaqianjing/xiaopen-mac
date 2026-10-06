// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XiaoPen",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "XiaoPen",
            targets: ["XiaoPen"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "XiaoPen",
            dependencies: [],
            path: "Sources/XiaoPen",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "XiaoPenTests",
            dependencies: ["XiaoPen"],
            path: "Tests/XiaoPenTests"
        )
    ]
)
