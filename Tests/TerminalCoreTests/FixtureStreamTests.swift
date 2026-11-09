import Foundation
import Testing
@testable import TerminalCore

/// spec: terminal-engine「Recorded agent streams are processed deterministically」。
///
/// フィクスチャは webtabinal の tests/fixtures/agents をコピーしたもの（`make fixtures`、出典は Tests/Fixtures/SOURCE）。
/// 期待する画面テキストはフィクスチャに無いので、書き込み方によらず結果が同じになることだけを確かめる（design D9）。
@Suite struct FixtureStreamTests {
    struct Fixture: CustomTestStringConvertible, Sendable {
        let name: String
        let columns: Int
        let rows: Int
        let stream: [UInt8]

        var testDescription: String { name }
    }

    private struct Metadata: Decodable {
        let rows: Int
        let columns: Int
    }

    static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/agents")

    static func loadFixtures() throws -> [Fixture] {
        guard let enumerator = FileManager.default.enumerator(at: fixturesRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var fixtures: [Fixture] = []
        for case let url as URL in enumerator where url.lastPathComponent == "stream.raw" {
            let directory = url.deletingLastPathComponent()
            let metadata = try JSONDecoder().decode(
                Metadata.self,
                from: Data(contentsOf: directory.appendingPathComponent("metadata.json"))
            )
            let name = String(directory.path.dropFirst(fixturesRoot.path.count + 1))
            fixtures.append(Fixture(
                name: name,
                columns: metadata.columns,
                rows: metadata.rows,
                stream: Array(try Data(contentsOf: url))
            ))
        }
        return fixtures.sorted { $0.name < $1.name }
    }

    static let fixtures: [Fixture] = (try? loadFixtures()) ?? []

    private func makeTerminal(_ fixture: Fixture) throws -> VTTerminal {
        try VTTerminal(cols: fixture.columns, rows: fixture.rows, maxScrollback: 10_000)
    }

    @Test func fixturesArePresent() throws {
        // webtabinal のチェックアウトが無くても、コミット済みのフィクスチャで実行できる。
        #expect(try Self.loadFixtures().count >= 20)
    }

    // Scenario: Chunking invariance on fixtures
    @Test(arguments: fixtures)
    func chunkingDoesNotChangeTheScreen(fixture: Fixture) throws {
        let whole = try makeTerminal(fixture)
        whole.write(fixture.stream)

        let chunked = try makeTerminal(fixture)
        let chunkSize = 24 * 1024 // デーモンの replay のチャンクサイズ
        var offset = 0
        while offset < fixture.stream.count {
            let end = min(offset + chunkSize, fixture.stream.count)
            chunked.write(fixture.stream[offset..<end])
            offset = end
        }

        let byteByByte = try makeTerminal(fixture)
        for byte in fixture.stream {
            byteByByte.write(CollectionOfOne(byte))
        }

        let expected = try whole.plainText()
        #expect(!fixture.stream.isEmpty)
        #expect(try chunked.plainText() == expected)
        #expect(try byteByByte.plainText() == expected)
    }

    // design の Risk: replay の先頭は、シーケンスやUTF-8 の途中から始まることがある。
    @Test(arguments: fixtures)
    func truncatedHeadIsTolerated(fixture: Fixture) throws {
        for dropped in 1...7 where dropped < fixture.stream.count {
            let terminal = try makeTerminal(fixture)
            terminal.write(fixture.stream.dropFirst(dropped))
            _ = terminal.takeEffects()
            // 壊れた先頭を読み飛ばして処理を続け、その後の書き込みも普通に反映される。
            terminal.write(Array("\u{1b}[0m\r\nTAIL-MARKER".utf8))
            #expect(try terminal.plainText().contains("TAIL-MARKER"))
        }
    }
}
