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
        .target(
            name: "PearControllerHID",
            path: "runtime/host/controller-hid",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("GameController"), .linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "PearSilicon",
            dependencies: [
                "PearControllerHID",
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
