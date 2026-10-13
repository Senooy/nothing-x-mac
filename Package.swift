// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NothingX",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "NothingX",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NothingX",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NothingXTests",
            dependencies: ["NothingX"],
            path: "Tests/NothingXTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
