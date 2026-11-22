// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PearSilicon",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "PearSilicon", targets: ["PearSilicon"])
    ],
    dependencies: [
        // PearDebug: integrated directly under runtime/debug.
        .package(path: "runtime/debug")
    ],
    targets: [
        .executableTarget(
            name: "PearSilicon",
            dependencies: [
                .product(name: "PearDebugKit", package: "debug")
            ],
            path: "Sources/PearSilicon",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PearSiliconTests",
            dependencies: ["PearSilicon"],
            path: "Tests/PearSiliconTests"
        )
    ]
)
