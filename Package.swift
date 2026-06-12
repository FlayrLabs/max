// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Max",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Max",
            path: "Sources/Max",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
