// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "QalamMac",
    platforms: [.macOS(.v15)],
    targets: [
        // Wire format, the two links, display targeting, cursor injection: shared by both apps.
        .target(name: "QalamCore", path: "Sources/QalamCore", swiftSettings: v5),
        // The menu-bar app: cursor mode + the ink overlay. Bundled by scripts/build-mac-app.sh.
        .executableTarget(name: "Qalam", dependencies: ["QalamCore"], path: "Sources/Qalam", swiftSettings: v5),
        // Command-line receiver with a latency/jitter log (cursor mode only), for testing links.
        .executableTarget(name: "qalam-m0", dependencies: ["QalamCore"], path: "Sources/qalam-m0", swiftSettings: v5),
    ]
)
