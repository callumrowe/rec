// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "rec",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1"),
    ],
    targets: [
        .executableTarget(
            name: "rec",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/rec",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
