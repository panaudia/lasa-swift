// swift-tools-version: 6.0
// lasa-swift: the Swift LASA client (lasa-planning/plan/lasa-swift.md).
// Lifted from lasa-ios-probe's ProbeKit on 2026-11-03.
import PackageDescription

let package = Package(
    name: "lasa-swift",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "LasaSwift", targets: ["LasaSwift"]),
        .library(name: "CRings", targets: ["CRings"]),
    ],
    targets: [
        // The single-producer single-consumer float ring, shared with the
        // Go probe archive (same source compiled by cgo there).
        .target(name: "CRings", publicHeadersPath: "include"),
        // libopus 1.5.2, static, device + simulator + macOS, built by
        // scripts/build-opus.sh. BSD-3-Clause: LICENSES/opus.txt.
        .binaryTarget(name: "opus", path: "opus.xcframework"),
        // libopus's headers and the non-variadic ctl shims.
        .target(name: "COpus", dependencies: ["opus"], publicHeadersPath: "include"),
        .target(
            name: "LasaSwift",
            dependencies: ["CRings", "COpus"]
        ),
        .testTarget(
            name: "LasaSwiftTests",
            dependencies: ["LasaSwift"],
            // The Go jitterlab traces and reassembler fixtures, replayed
            // for ledger equality, and the wire vectors.
            resources: [.copy("Fixtures")]
        ),
    ]
)
