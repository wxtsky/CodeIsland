// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle — auto-update framework. Pinned to 2.6+ for stable
        // SPUStandardUpdaterController + ed25519 signature verification.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CodeIslandCore",
            path: "Sources/CodeIslandCore"
        ),
        .executableTarget(
            name: "CodeIsland",
            dependencies: [
                "CodeIslandCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/CodeIsland",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "codeisland-bridge",
            dependencies: ["CodeIslandCore"],
            path: "Sources/CodeIslandBridge"
        ),
        .testTarget(
            name: "CodeIslandCoreTests",
            dependencies: ["CodeIslandCore"],
            path: "Tests/CodeIslandCoreTests"
        ),
        .testTarget(
            name: "CodeIslandTests",
            dependencies: ["CodeIsland"],
            path: "Tests/CodeIslandTests"
        ),
    ]
)
