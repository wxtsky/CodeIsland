// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UniIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle — auto-update framework. Pinned to 2.6+ for stable
        // SPUStandardUpdaterController + ed25519 signature verification.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "UniIslandCore",
            path: "Sources/UniIslandCore"
        ),
        .executableTarget(
            name: "UniIsland",
            dependencies: [
                "UniIslandCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/UniIsland",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "uniisland-bridge",
            dependencies: ["UniIslandCore"],
            path: "Sources/UniIslandBridge"
        ),
        .testTarget(
            name: "UniIslandCoreTests",
            dependencies: ["UniIslandCore"],
            path: "Tests/UniIslandCoreTests"
        ),
        .testTarget(
            name: "UniIslandTests",
            dependencies: [
                "UniIsland",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/UniIslandTests"
        ),
    ]
)
