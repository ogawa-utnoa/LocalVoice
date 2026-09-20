// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalVoiceInput",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LocalVoiceInputCore",
            targets: ["LocalVoiceInputCore"]
        ),
        .executable(
            name: "LocalVoiceInputApp",
            targets: ["LocalVoiceInputApp"]
        ),
        .executable(
            name: "LocalVoiceInputTests",
            targets: ["LocalVoiceInputTests"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LocalVoiceInputCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "LocalVoiceInputApp",
            dependencies: ["LocalVoiceInputCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "LocalVoiceInputTests",
            dependencies: ["LocalVoiceInputCore"],
            path: "Tests/LocalVoiceInputTests"
        )
    ]
)
