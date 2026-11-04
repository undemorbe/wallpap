// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallpap",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Wallpap",
            path: "Sources/Wallpap"
        )
    ],
    swiftLanguageModes: [.v5]
)
