// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tabghostty",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tabghostty", targets: ["Tabghostty"]),
        .library(name: "TerminalCore", targets: ["TerminalCore"]),
    ],
    targets: [
        .executableTarget(
            name: "Tabghostty",
            dependencies: ["TerminalCore"]
        ),
        // libghostty-vt 1.0（静的ライブラリの XCFramework。`make deps` で取得する）。
        // Headers/module.modulemap が `module GhosttyVt` を宣言しているので、そのまま import できる。
        .binaryTarget(
            name: "GhosttyVt",
            path: "Vendor/GhosttyVt.xcframework"
        ),
        .target(
            name: "TerminalCore",
            dependencies: ["GhosttyVt"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
