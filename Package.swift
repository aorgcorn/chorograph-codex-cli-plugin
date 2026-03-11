// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChorographCodexCLIPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "ChorographCodexCLIPlugin",
            type: .dynamic,
            targets: ["ChorographCodexCLIPlugin"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/chorograph/chorograph.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ChorographCodexCLIPlugin",
            dependencies: [
                .product(name: "ChorographPluginSDK", package: "chorograph"),
            ]
        ),
    ]
)
