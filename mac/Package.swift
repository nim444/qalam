// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QalamMac",
    platforms: [.macOS(.v15)],
    targets: [
        // M0 feel test: receives pen frames from the phone and drives the Mac cursor.
        .executableTarget(
            name: "qalam-m0",
            path: "Sources/qalam-m0",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
