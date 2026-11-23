// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dizun",
    platforms: [.macOS(.v14)],
    targets: [
        // UI-independent ZIP engine. No AppKit, no network, no third-party code.
        .target(name: "DizunCore"),
        // Vendored non-ZIP engine (tar/7z/RAR/LZH). Built from pinned sources
        // by scripts/vendor/build-vendor.sh; regenerate before building.
        .binaryTarget(name: "LibarchiveXCF", path: "vendor/libarchive.xcframework"),
        .binaryTarget(name: "LiblzmaXCF", path: "vendor/liblzma.xcframework"),
        // C shim: exposes libarchive headers and links the system codecs.
        .target(name: "CArchive",
                dependencies: ["LibarchiveXCF", "LiblzmaXCF"],
                path: "Sources/CArchive"),
        // Swift wrapper over libarchive for the multi-format adapters.
        .target(name: "DizunArchive", dependencies: ["CArchive", "DizunCore"]),
        // System-zlib shim (Apple-shipped library; PNG recompression needs
        // level control the Compression framework does not expose).
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        // Lossless-first image optimizer (PNG/JPEG). Apple frameworks only.
        .target(name: "DizunImage", dependencies: ["CZlib"]),
        // Synthetic archive builders and Gate-B verification scenarios, shared by
        // the XCTest suite and the `dizun selftest` CLI. Not part of the app.
        .target(name: "DizunFixtures", dependencies: ["DizunCore", "DizunImage"]),
        // Manual verification CLI: pack / unpack / list / optimize / selftest.
        .executableTarget(name: "dizun",
                          dependencies: ["DizunCore", "DizunImage", "DizunFixtures", "DizunArchive"]),
        // Finder-facing app shell: archive-open extraction, Services, droplet.
        // Packaged into Dizun.app by scripts/build-app.sh.
        .executableTarget(name: "DizunApp", dependencies: ["DizunCore", "DizunImage", "DizunArchive"]),
        .testTarget(name: "DizunCoreTests", dependencies: ["DizunCore", "DizunFixtures"]),
        .testTarget(name: "DizunArchiveTests", dependencies: ["DizunArchive"]),
    ]
)
