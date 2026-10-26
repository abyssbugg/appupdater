// swift-tools-version: 6.3
// AppUpdater — hybrid macOS updater (MacUpdater engine + Updatest source strategy)
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppUpdaterCore", targets: ["AppUpdaterCore"]),
        .executable(name: "AppUpdaterApp", targets: ["AppUpdaterApp"]),
    ],
    targets: [
        // Engine: scanner, sources (cask/sparkle/MAS), version oracle, installer (later phases)
        .target(name: "AppUpdaterCore"),
        // Front shell: menu-bar item + normal window (both, per owner requirement)
        .executableTarget(
            name: "AppUpdaterApp",
            dependencies: ["AppUpdaterCore"]
        ),
        .testTarget(name: "AppUpdaterCoreTests", dependencies: ["AppUpdaterCore"]),
    ]
)
