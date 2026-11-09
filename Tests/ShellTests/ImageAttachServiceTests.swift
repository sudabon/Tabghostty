import AppKit
import DaemonClient
import Foundation
import Testing
import TerminalUI
@testable import Shell

/// spec: image-attach「Upload and type paths」（tasks 5.2）。
@MainActor
@Suite(.serialized) struct ImageAttachServiceTests {
    private let png = AttachableImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
    private let jpeg = AttachableImage(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")
    private let support = "/Users/me/Library/Application Support/WebTabinal/images"

    private func typed(_ harness: ShellHarness) async throws -> String {
        _ = await waitUntil { !harness.sink.inputBytes.isEmpty }
        try await Task.sleep(for: .milliseconds(30))
        return String(decoding: harness.sink.inputBytes, as: UTF8.self)
    }

    // Scenario: Several files — 1 つずつ順に送り、エスケープしたパスをスペースで区切って、末尾にもスペースを付ける。
    @Test func severalImagesAreUploadedInOrderAndTypedWithATrailingSpace() async throws {
        let uploader = FakeImageUploader(results: ["\(support)/img-1.png", "\(support)/img-2.jpg"])
        let harness = try ShellHarness(uploader: uploader)
        await harness.liveSessions([session("a"), session("b")])
        harness.sink.removeAll()

        let text = await harness.shell.imageAttach?.attach([png, jpeg])
        let expected = "/Users/me/Library/Application\\ Support/WebTabinal/images/img-1.png "
            + "/Users/me/Library/Application\\ Support/WebTabinal/images/img-2.jpg "
        #expect(text == expected)
        #expect(uploader.uploads.map(\.sid) == ["a", "a"])
        #expect(uploader.uploads.map(\.mime) == ["image/png", "image/jpeg"])
        #expect(uploader.uploads.map(\.data) == [png.data, jpeg.data])
        #expect(try await typed(harness) == expected)
    }

    // Scenario: One failure — 失敗した画像は飛ばし、成功したものだけを入力する。
    @Test func failedUploadsAreSkipped() async throws {
        let uploader = FakeImageUploader(results: [nil, "/tmp/ok.png"])
        let harness = try ShellHarness(uploader: uploader)
        await harness.liveSessions([session("a")])
        harness.sink.removeAll()
        #expect(await harness.shell.imageAttach?.attach([png, jpeg]) == "/tmp/ok.png ")
        #expect(uploader.uploads.count == 2)
        #expect(try await typed(harness) == "/tmp/ok.png ")
    }

    // すべて失敗したら、何も入力しない。
    @Test func nothingIsTypedWhenEveryUploadFails() async throws {
        let uploader = FakeImageUploader(results: [nil])
        let harness = try ShellHarness(uploader: uploader)
        await harness.liveSessions([session("a")])
        harness.sink.removeAll()
        #expect(await harness.shell.imageAttach?.attach([png]) == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.sink.inputBytes.isEmpty)
    }

    // Scenario: Tab switched during upload — どちらのセッションにも入力しない。
    @Test func switchingTabsDuringUploadTypesNothing() async throws {
        let uploader = FakeImageUploader(results: ["/tmp/a.png"])
        uploader.held = true
        let harness = try ShellHarness(uploader: uploader)
        await harness.liveSessions([session("a"), session("b")])
        harness.sink.removeAll()

        #expect(harness.store.activeSessionID == "a")
        let attach = Task { await harness.shell.imageAttach?.attach([png]) }
        #expect(await waitUntil { uploader.uploads.count == 1 })
        harness.shell.select("b")
        uploader.held = false
        #expect(await attach.value == nil)
        #expect(uploader.uploads.map(\.sid) == ["a"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.sink.inputBytes.isEmpty)
    }

    // live でなければ入力しない（通常のペーストの経路と同じ）。
    @Test func nothingIsTypedIntoASessionThatIsNotLive() async throws {
        let uploader = FakeImageUploader(results: ["/tmp/a.png"])
        let harness = try ShellHarness(uploader: uploader)
        await harness.deliver(.sessions([session("a")]))
        harness.sink.removeAll()
        _ = await harness.shell.imageAttach?.attach([png])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!harness.sink.frames.contains { if case .input = $0 { true } else { false } })
    }

    // Scenario: Paste a screenshot into Claude Code — Command-V の画像がアップロードされ、パスとスペースが入力される。
    // bracketed paste が有効なら、ペーストとして囲む。
    @Test func commandVWithAScreenshotTypesThePath() async throws {
        let uploader = FakeImageUploader(results: ["/tmp/shot.png"])
        let harness = try ShellHarness(uploader: uploader)
        await harness.liveSessions([session("a")])
        await harness.deliver(.output(sid: "a", data: Array("\u{1b}[?2004h".utf8)))
        let board = NSPasteboard(name: NSPasteboard.Name("Tabghostty.tests.\(UUID().uuidString)"))
        board.clearContents()
        board.declareTypes([.png, .string], owner: nil)
        board.setData(png.data, forType: .png)
        board.setString("ignored", forType: .string)
        harness.terminalView.pasteboard = board
        harness.sink.removeAll()

        harness.terminalView.paste(nil)
        #expect(try await typed(harness) == "\u{1b}[200~/tmp/shot.png \u{1b}[201~")
        #expect(uploader.uploads.map(\.mime) == ["image/png"])
    }
}
