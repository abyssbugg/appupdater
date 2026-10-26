// swift-tools-version: 6.3
// AppUpdater — hybrid macOS updater (MacUpdater engine + Updatest source strategy)
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppUpdaterCore", targets: ["AppUpdaterCore"]),
        .executable(name: "AppUpdaterApp", targets: ["AppUpdaterApp"]),
        .executable(name: "appupdater-cli", targets: ["appupdater-cli"]),
    ],
    dependencies: [
        // Self-update ONLY (LOCKED decision 8). Pinned exactly for reproducible
        // release builds; AppUpdaterCore stays dependency-free by design.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Engine: scanner, sources (cask/sparkle/MAS), version oracle, installer (later phases)
        .target(name: "AppUpdaterCore"),
        // Front shell: menu-bar item + normal window (both, per owner requirement)
        .executableTarget(
            name: "AppUpdaterApp",
            dependencies: [
                "AppUpdaterCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // Scriptable surface: scan + live-check with honest JSON reports (Phase 2 gate instrument).
        .executableTarget(
            name: "appupdater-cli",
            dependencies: ["AppUpdaterCore"]
        ),
        .testTarget(name: "AppUpdaterCoreTests", dependencies: ["AppUpdaterCore"]),
    ]
)
