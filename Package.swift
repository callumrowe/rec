// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "rec",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "rec",
            path: "Sources/rec",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
