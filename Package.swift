// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NothingX",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "NothingX",
            path: "Sources/NothingX",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
