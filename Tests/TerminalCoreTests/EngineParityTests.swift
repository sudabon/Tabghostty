import Foundation
import Testing
@testable import TerminalCore

/// spec: engine-parity — デーモンの画面モデル（libghostty 版）が生成した最終画面と、Tabghostty のエンジンの画面が一致する（phase6 design D5）。
///
/// 手順は「バージョンを照合する → フィクスチャを流す → screen.txt と比べる」。
/// screen.txt は同梱のデーモン（`daemon/`）の `-update-screens` だけが生成し、`make screens` で作り直して取り込む。
/// screen.txt の無いフィクスチャは skip する（テストケースを cancel する）。
@Suite struct EngineParityTests {
    /// screen.meta.json（`daemon/internal/agentdetect/screens_test.go` の `-update-screens` が書く。phase6 design D2）。
    struct ReferenceMetadata: Decodable {
        /// 画面を作った画面モデル。一致検証に使えるのは "ghostty" だけ。
        let screenModel: String
        /// 画面を作った libghostty-vt の `ghostty_version()`。
        let libghosttyVtVersion: String

        enum CodingKeys: String, CodingKey {
            case screenModel = "screen_model"
            case libghosttyVtVersion = "libghostty_vt_version"
        }
    }

    static let referenceFileName = "screen.txt"
    static let metadataFileName = "screen.meta.json"

    /// screen.txt を行に分ける。最後の改行の後ろは行に数えない。
    static func referenceLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// 行ごとに UTF-8 のバイト列で比べ（正準等価では比べない）、違う行を返す。
    static func mismatches(expected: [String], actual: [String]) -> [(line: Int, expected: String?, actual: String?)] {
        (0..<max(expected.count, actual.count)).compactMap { index in
            let want = index < expected.count ? expected[index] : nil
            let got = index < actual.count ? actual[index] : nil
            if let want, let got, want.utf8.elementsEqual(got.utf8) { return nil }
            return (index + 1, want, got)
        }
    }

    // Scenario: Fixture parity / Reference missing / Version mismatch
    @Test(arguments: FixtureStreamTests.fixtures)
    func fixtureScreenMatchesTheDaemon(fixture: FixtureStreamTests.Fixture) throws {
        let directory = FixtureStreamTests.fixturesRoot.appendingPathComponent(fixture.name)
        let referenceURL = directory.appendingPathComponent(Self.referenceFileName)
        guard FileManager.default.fileExists(atPath: referenceURL.path) else {
            try Test.cancel("\(Self.referenceFileName) が無いので skip する: \(fixture.name)")
        }

        // 1. バージョンを照合する。違えば比べずに失敗する。
        let metadataURL = directory.appendingPathComponent(Self.metadataFileName)
        let metadata = try #require(
            try? JSONDecoder().decode(ReferenceMetadata.self, from: Data(contentsOf: metadataURL)),
            "\(fixture.name): \(Self.metadataFileName) が無いか、読めない（screen_model と libghostty_vt_version が要る）"
        )
        try #require(
            metadata.screenModel == "ghostty",
            "\(fixture.name): \(Self.referenceFileName) は画面モデル \(metadata.screenModel) で生成されている（ghostty のものだけと比べる）"
        )
        let linked = GhosttySystem.libraryVersion
        try #require(
            metadata.libghosttyVtVersion == linked,
            "\(fixture.name): \(Self.referenceFileName) は libghostty-vt \(metadata.libghosttyVtVersion) で生成されたが、Tabghostty がリンクしているのは libghostty-vt \(linked)"
        )

        // 2. フィクスチャを、フィクスチャのサイズの端末に流す。
        let terminal = try VTTerminal(cols: fixture.columns, rows: fixture.rows, maxScrollback: 0)
        terminal.write(fixture.stream)

        // 3. 正規化した表示中の行を、screen.txt と行ごとに比べる。
        let expected = Self.referenceLines(try String(contentsOf: referenceURL, encoding: .utf8))
        let actual = terminal.normalizedScreenLines()
        let mismatches = Self.mismatches(expected: expected, actual: actual)
        if !mismatches.isEmpty {
            let quoted = { (line: String?) in line.map { "\"\($0)\"" } ?? "（行が無い）" }
            let details = mismatches.map { mismatch in
                "  \(mismatch.line) 行目\n    screen.txt: \(quoted(mismatch.expected))\n    Tabghostty: \(quoted(mismatch.actual))"
            }
            Issue.record(
                "\(fixture.name): \(mismatches.count) 行が違う（screen.txt \(expected.count) 行、Tabghostty \(actual.count) 行）\n\(details.joined(separator: "\n"))"
            )
        }
    }

    // Scenario: Reference missing — cancel したテストケースは、swift test のコンソールでは passed と表示される
    // （event stream では testCaseCancelled）。一致検証をしていないことが分かるように、件数を出力する。
    @Test func reportsHowManyFixturesHaveReferenceScreens() {
        let fixtures = FixtureStreamTests.fixtures
        let skipped = fixtures.filter { fixture in
            let url = FixtureStreamTests.fixturesRoot.appendingPathComponent(fixture.name).appendingPathComponent(Self.referenceFileName)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        print("engine-parity: \(Self.referenceFileName) のあるフィクスチャ \(fixtures.count - skipped.count)/\(fixtures.count) 件で一致を検証する（skip \(skipped.count) 件）")
        #expect(!fixtures.isEmpty)
    }

    // MARK: - 比べ方そのもの

    @Test func referenceLinesIgnoreOnlyTheFinalNewline() {
        #expect(Self.referenceLines("a\nb\n") == ["a", "b"])
        #expect(Self.referenceLines("a\nb") == ["a", "b"])
        #expect(Self.referenceLines("a\n\n") == ["a", ""])
        #expect(Self.referenceLines("") == [""])
    }

    @Test func mismatchesCompareBytesAndLineCounts() {
        #expect(Self.mismatches(expected: ["a", "b"], actual: ["a", "b"]).isEmpty)
        // 正準等価でも、バイト列が違えば違う行として扱う。
        let composed = Self.mismatches(expected: ["\u{e9}"], actual: ["e\u{301}"])
        #expect(composed.map(\.line) == [1])
        let missing = Self.mismatches(expected: ["a", "b"], actual: ["a"])
        #expect(missing.map(\.line) == [2])
        #expect(missing.first?.actual == nil)
    }
}
