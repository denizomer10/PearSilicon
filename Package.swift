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
        // PearDebug: log sessions, log analysis and engine probes.
        // https://github.com/denizomer10/PearDebug (git submodule)
        .package(path: "Vendor/PearDebug"),
        .package(path: "Vendor/PearWine")
    ],
    targets: [
        .executableTarget(
            name: "PearSilicon",
            dependencies: [
                .product(name: "PearDebugKit", package: "PearDebug"),
                .product(name: "PearWineKit", package: "PearWine")
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
