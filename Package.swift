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
        ),
        .executable(
            name: "XiaoPenSpeechWorker",
            targets: ["XiaoPenSpeechWorker"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "dbe5eaac964e8257785f9d015c81f819a38016a8"
        ),
        // Pin the runtime and tokenizer APIs to make local inference builds
        // reproducible without upgrading the Hub client unexpectedly.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.8.1")
    ],
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
        // MLX lives in a separate process so stopping speech immediately releases
        // inference work without affecting microphone capture or the app's UI.
        .executableTarget(
            name: "XiaoPenSpeechWorker",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift")
            ],
            path: "Sources/XiaoPenSpeechWorker"
        ),
        .testTarget(
            name: "XiaoPenTests",
            dependencies: ["XiaoPen"],
            path: "Tests/XiaoPenTests"
        )
    ]
)
