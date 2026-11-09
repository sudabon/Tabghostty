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
            dependencies: ["TabghosttyApp"]
        ),
        // アプリの外枠（AppDelegate、ウィンドウ、メニュー、起動失敗画面、トースト）。
        .target(
            name: "TabghosttyApp",
            dependencies: ["DaemonClient", "TerminalUI", "TerminalCore"]
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
        // webtabinal `desktop/Sources/DesktopSupport.swift` からの移植（ポートの解析、デーモンのプローブ、デタッチ起動、通知）。
        .target(
            name: "DesktopSupport"
        ),
        // 端末の描画（Core Text）、フォント、配色、グリッドのサイズ、キー入力。
        .target(
            name: "TerminalUI",
            dependencies: ["TerminalCore"]
        ),
        // デーモンとの接続（config、デーモンの検出と起動、REST、WebSocket、セッション一覧）。
        .target(
            name: "DaemonClient",
            dependencies: ["DesktopSupport", "TerminalCore"]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"]
        ),
        .testTarget(
            name: "DesktopSupportTests",
            dependencies: ["DesktopSupport"]
        ),
        .testTarget(
            name: "TerminalUITests",
            dependencies: ["TerminalUI", "TerminalCore"]
        ),
        .testTarget(
            name: "TabghosttyAppTests",
            dependencies: ["TabghosttyApp"]
        ),
        .testTarget(
            name: "DaemonClientTests",
            dependencies: ["DaemonClient", "DesktopSupport", "TerminalCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
