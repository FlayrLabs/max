// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AskMax",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "AskMax",
            path: "Sources/AskMax",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
