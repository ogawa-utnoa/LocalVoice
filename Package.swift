// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalVoice",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LocalVoiceCore",
            targets: ["LocalVoiceCore"]
        ),
        .executable(
            name: "LocalVoiceApp",
            targets: ["LocalVoiceApp"]
        ),
        .executable(
            name: "LocalVoiceTests",
            targets: ["LocalVoiceTests"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LocalVoiceCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "LocalVoiceApp",
            dependencies: ["LocalVoiceCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "LocalVoiceTests",
            dependencies: ["LocalVoiceCore"],
            path: "Tests/LocalVoiceTests"
        )
    ]
)
