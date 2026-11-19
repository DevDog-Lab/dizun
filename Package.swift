// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dizun",
    platforms: [.macOS(.v14)],
    targets: [
        // UI-independent ZIP engine. No AppKit, no network, no third-party code.
        .target(name: "DizunCore"),
        // Synthetic archive builders and Gate-B verification scenarios, shared by
        // the XCTest suite and the `dizun selftest` CLI. Not part of the app.
        .target(name: "DizunFixtures", dependencies: ["DizunCore"]),
        // Manual verification CLI: pack / unpack / list / selftest.
        .executableTarget(name: "dizun", dependencies: ["DizunCore", "DizunFixtures"]),
        // Finder-facing app shell: archive-open extraction, Services, droplet.
        // Packaged into Dizun.app by scripts/build-app.sh.
        .executableTarget(name: "DizunApp", dependencies: ["DizunCore"]),
        .testTarget(name: "DizunCoreTests", dependencies: ["DizunCore", "DizunFixtures"]),
    ]
)
