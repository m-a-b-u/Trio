// swift-tools-version: 6.0
import PackageDescription

// Exercises the real display model with synthetic snapshots, without launching an app.
let package = Package(
    name: "TrioMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TrioMenuBar",
            path: ".",
            exclude: ["Tests", "TrioMenuBarApp.swift", "Info.plist", "TrioMenuBar.entitlements"],
            sources: ["TrioMenuBarStatusModel.swift", "Shared/TrioStatusSnapshot.swift", "Shared/TrioStatusSnapshotStore.swift"]
        ),
        .testTarget(name: "TrioMenuBarTests", dependencies: ["TrioMenuBar"], path: "Tests")
    ]
)
