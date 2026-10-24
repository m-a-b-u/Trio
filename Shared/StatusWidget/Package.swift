// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrioStatusWidgetCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "TrioStatusWidgetCore", targets: ["TrioStatusWidgetCore"])],
    targets: [
        .target(
            name: "TrioStatusWidgetCore",
            path: ".",
            exclude: ["Tests"],
            sources: ["TrioStatusSnapshot.swift", "TrioStatusSnapshotStore.swift"]
        ),
        .testTarget(name: "TrioStatusWidgetCoreTests", dependencies: ["TrioStatusWidgetCore"], path: "Tests")
    ]
)
