// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SnipReel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnipReel",
            path: "Sources/SnipReel",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
