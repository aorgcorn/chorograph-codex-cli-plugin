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
            url: "https://github.com/aorgcorn/chorograph-plugin-sdk.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ChorographCodexCLIPlugin",
            dependencies: [
                .product(name: "ChorographPluginSDK", package: "chorograph-plugin-sdk"),
            ],
            linkerSettings: [
                // Ensure the plugin resolves libChorographPluginSDK.dylib from
                // the host process rather than a bundled copy.
                // @executable_path/../Frameworks — proper .app bundle layout
                // @executable_path              — SPM / swift run (.build/debug/)
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
    ]
)
