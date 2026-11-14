// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnipReel",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 自動アップデート
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "SnipReel",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
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
