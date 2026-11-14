// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnipReel",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SnipReel",
            path: "Sources/SnipReel",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
