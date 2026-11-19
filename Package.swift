// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dizun",
    platforms: [.macOS(.v14)],
    targets: [
        // UI-independent ZIP engine. No AppKit, no network, no third-party code.
        .target(name: "DizunCore"),
        // System-zlib shim (Apple-shipped library; PNG recompression needs
        // level control the Compression framework does not expose).
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        // Lossless-first image optimizer (PNG/JPEG). Apple frameworks only.
        .target(name: "DizunImage", dependencies: ["CZlib"]),
        // Synthetic archive builders and Gate-B verification scenarios, shared by
        // the XCTest suite and the `dizun selftest` CLI. Not part of the app.
        .target(name: "DizunFixtures", dependencies: ["DizunCore", "DizunImage"]),
        // Manual verification CLI: pack / unpack / list / optimize / selftest.
        .executableTarget(name: "dizun", dependencies: ["DizunCore", "DizunImage", "DizunFixtures"]),
        // Finder-facing app shell: archive-open extraction, Services, droplet.
        // Packaged into Dizun.app by scripts/build-app.sh.
        .executableTarget(name: "DizunApp", dependencies: ["DizunCore", "DizunImage"]),
        .testTarget(name: "DizunCoreTests", dependencies: ["DizunCore", "DizunFixtures"]),
    ]
)
