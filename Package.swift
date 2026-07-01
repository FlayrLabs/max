// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Max",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.5.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Max",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: "Sources/Max",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
