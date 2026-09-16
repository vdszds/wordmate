// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LocalTranscriber",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "LocalTranscriber",
            targets: ["LocalTranscriber"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.6"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "10628974fa6f996bb1ca9791dd93113292b79e3b"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.1.9"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LocalTranscriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/LocalTranscriber",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal"),
            ]
        ),
        .testTarget(
            name: "LocalTranscriberTests",
            dependencies: ["LocalTranscriber"],
            path: "Tests/LocalTranscriberTests"
        ),
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx17
)
