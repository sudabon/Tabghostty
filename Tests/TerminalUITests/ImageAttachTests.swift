import AppKit
import Testing
import TerminalCore
import UniformTypeIdentifiers
@testable import TerminalUI

/// spec: image-attach「Upload and type paths」「Image sources」（tasks 5.1）。
///
/// webtabinal `web/tests/image-attach.test.ts` のうち、ブラウザの API（`clipboard.read`、Blob）に依存しないケースを移したもの。
@Suite struct ImageAttachPortTests {
    // only the image types every agent reads are attachable
    @Test func onlyTheImageTypesEveryAgentReadsAreAttachable() {
        for type in ["image/png", "image/jpeg", "image/gif", "image/webp"] {
            #expect(ImageAttach.isAttachableImageType(type), "\(type)")
        }
        // SVG はスクリプトを含められ、どのエージェントも要らない。ほかは画像ではない。
        for type in ["image/svg+xml", "text/plain", "application/pdf", "", nil] as [String?] {
            #expect(!ImageAttach.isAttachableImageType(type), "\(String(describing: type))")
        }
    }

    // image type matching ignores parameters and case
    @Test func imageTypeMatchingIgnoresParametersAndCase() {
        #expect(ImageAttach.isAttachableImageType("image/PNG"))
        #expect(ImageAttach.isAttachableImageType("image/jpeg; charset=binary"))
    }

    // attachableImages keeps only images and tolerates an absent list
    @Test func attachableImagesKeepsOnlyImagesAndToleratesAnEmptyList() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("a.png")
        let text = directory.appendingPathComponent("notes.txt")
        let webp = directory.appendingPathComponent("b.webp")
        try pngBytes.write(to: png)
        try Data("notes".utf8).write(to: text)
        try webpBytes.write(to: webp)
        #expect(ImageAttach.attachableImages(at: [png, text, webp]).map(\.mimeType) == ["image/png", "image/webp"])
        #expect(ImageAttach.attachableImages(at: []).isEmpty)
    }

    // a drag is claimed only when it carries files
    @Test func aDragIsClaimedOnlyWhenItCarriesFiles() {
        let files = pasteboard()
        files.writeObjects([URL(fileURLWithPath: "/tmp/a.png") as NSURL])
        #expect(ImageAttach.dragCarriesFiles(files))
        // タブの並べ替えは文字列をドラッグするので、サイドバーに任せる。
        let text = pasteboard()
        text.setString("s1", forType: .string)
        #expect(!ImageAttach.dragCarriesFiles(text))
        #expect(!ImageAttach.dragCarriesFiles(pasteboard()))
    }

    // the support directory space is escaped the way a terminal escapes a dropped path
    @Test func theSupportDirectorySpaceIsEscaped() {
        #expect(
            ImageAttach.escapeTerminalPath("/Users/me/Library/Application Support/WebTabinal/images/img-1.png")
                == "/Users/me/Library/Application\\ Support/WebTabinal/images/img-1.png"
        )
    }

    // shell metacharacters anywhere in the path are escaped
    @Test func shellMetacharactersAnywhereInThePathAreEscaped() {
        #expect(ImageAttach.escapeTerminalPath("/tmp/a b/c'd/e$f/g;h.png") == "/tmp/a\\ b/c\\'d/e\\$f/g\\;h.png")
        #expect(ImageAttach.escapeTerminalPath("/tmp/back\\slash.png") == "/tmp/back\\\\slash.png")
        #expect(ImageAttach.escapeTerminalPath("/tmp/plain/img-1.png") == "/tmp/plain/img-1.png")
        // spec に挙げたすべての文字。
        let special = " \t\n\"'\\$`&|;<>()*?[]{}!#"
        #expect(ImageAttach.escapeTerminalPath(special) == special.map { "\\\($0)" }.joined())
        // Web 版の正規表現と同じく、1 文字（Unicode スカラー）ずつ見る。CR LF は 1 つの書記素だが、LF だけをエスケープする。
        // スペースのあとに結合文字が続いても、スペースをエスケープする。
        #expect(ImageAttach.escapeTerminalPath("/tmp/a\r\nb.png") == "/tmp/a\r\\\nb.png")
        #expect(ImageAttach.escapeTerminalPath("/tmp/a \u{301}b.png") == "/tmp/a\\ \u{301}b.png")
    }

    // terminal text separates paths and leaves a trailing space for the prompt
    @Test func terminalTextSeparatesPathsAndLeavesATrailingSpace() {
        #expect(ImageAttach.terminalText(forPaths: ["/tmp/a.png"]) == "/tmp/a.png ")
        #expect(ImageAttach.terminalText(forPaths: ["/tmp/a.png", "/tmp/b.png"]) == "/tmp/a.png /tmp/b.png ")
        // Scenario: Several files
        #expect(ImageAttach.terminalText(forPaths: ["/s/a b.png", "/s/c.jpg"]) == "/s/a\\ b.png /s/c.jpg ")
    }

    // terminal text for no usable path is empty, so nothing is typed
    @Test func terminalTextForNoUsablePathIsEmpty() {
        #expect(ImageAttach.terminalText(forPaths: []) == "")
        #expect(ImageAttach.terminalText(forPaths: ["", "   "]) == "")
    }
}

/// pasteboard とドロップしたファイルの読み取り（tasks 5.3 / 5.4）。
@Suite struct ImageSourceTests {
    // Command-V: PNG があればそのまま、無ければ TIFF を PNG にする。画像が無ければ nil（テキストのペーストに進む）。
    @Test func pasteboardBranches() throws {
        let png = pasteboard()
        png.setData(pngBytes, forType: .png)
        #expect(ImageAttach.pastedImage(from: png) == AttachableImage(data: pngBytes, mimeType: "image/png"))

        let tiff = pasteboard()
        tiff.setData(try tiffBytes(), forType: .tiff)
        let converted = try #require(ImageAttach.pastedImage(from: tiff))
        #expect(converted.mimeType == "image/png")
        #expect(ImageAttach.sniffMIMEType(converted.data) == "image/png")

        // Scenario: Image takes precedence — 画像とテキストの両方があれば画像。
        let both = pasteboard()
        both.declareTypes([.string, .png], owner: nil)
        both.setString("text", forType: .string)
        both.setData(pngBytes, forType: .png)
        #expect(ImageAttach.pastedImage(from: both)?.mimeType == "image/png")

        let text = pasteboard()
        text.setString("text only", forType: .string)
        #expect(ImageAttach.pastedImage(from: text) == nil)
        #expect(ImageAttach.pastedImage(from: pasteboard()) == nil)
    }

    @Test func typesAreDeterminedFromTheFileTypeOrContent() throws {
        #expect(ImageAttach.mimeType(for: .png) == "image/png")
        #expect(ImageAttach.mimeType(for: .jpeg) == "image/jpeg")
        #expect(ImageAttach.mimeType(for: .gif) == "image/gif")
        #expect(ImageAttach.mimeType(for: .webP) == "image/webp")
        #expect(ImageAttach.mimeType(for: .svg) == nil)
        #expect(ImageAttach.mimeType(for: .plainText) == nil)

        #expect(ImageAttach.sniffMIMEType(pngBytes) == "image/png")
        #expect(ImageAttach.sniffMIMEType(Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(ImageAttach.sniffMIMEType(Data("GIF89a....".utf8)) == "image/gif")
        #expect(ImageAttach.sniffMIMEType(webpBytes) == "image/webp")
        #expect(ImageAttach.sniffMIMEType(Data("hello".utf8)) == nil)

        // 拡張子の無いファイルは中身で決める。テキストに画像の拡張子が付いていても、種類で決める（デーモンが中身を確かめる）。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bare = directory.appendingPathComponent("screenshot")
        try pngBytes.write(to: bare)
        #expect(ImageAttach.attachableImage(at: bare)?.mimeType == "image/png")
        let script = directory.appendingPathComponent("image.svg")
        try Data("<svg/>".utf8).write(to: script)
        #expect(ImageAttach.attachableImage(at: script) == nil)
        let missing = directory.appendingPathComponent("gone.png")
        #expect(ImageAttach.attachableImage(at: missing) == nil)
        // macOS が知らない拡張子（動的な種類）は、ただのデータと同じく中身で決める。
        let unknownExtension = directory.appendingPathComponent("shot.xyzzy")
        try pngBytes.write(to: unknownExtension)
        #expect(ImageAttach.attachableImage(at: unknownExtension)?.mimeType == "image/png")
        let unknownText = directory.appendingPathComponent("notes.xyzzy")
        try Data("plain text".utf8).write(to: unknownText)
        #expect(ImageAttach.attachableImage(at: unknownText) == nil)
        // 種類の分かる、画像でないファイルは、中身が画像でも添付しない。
        let pdf = directory.appendingPathComponent("doc.pdf")
        try pngBytes.write(to: pdf)
        #expect(ImageAttach.attachableImage(at: pdf) == nil)
    }
}

/// `TerminalView` の Command-V とドロップ（tasks 5.3 / 5.4）。
@MainActor
@Suite struct TerminalViewImageTests {
    private struct Fixture {
        let view: TerminalView
        let sink: RecordingSink
        let pasteboard: NSPasteboard
        let window: NSWindow
    }

    private func makeFixture() async throws -> Fixture {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", cols: 40, rows: 6, maxScrollback: 100, colors: nil, sink: sink)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark)
        let size = NSSize(width: 400, height: 200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()
        view.controller = controller
        let board = pasteboard()
        view.pasteboard = board
        return Fixture(view: view, sink: sink, pasteboard: board, window: window)
    }

    private func sentText(_ sink: RecordingSink) async throws -> String {
        for _ in 0..<200 where sink.inputBytes.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        return String(decoding: sink.inputBytes.joined(), as: UTF8.self)
    }

    // Scenario: Image takes precedence — 画像があれば添付し、テキストはペーストしない。
    @Test func commandVAttachesTheImageInsteadOfPastingText() async throws {
        let fixture = try await makeFixture()
        var attached: [[AttachableImage]] = []
        fixture.view.imageAttachHandler = { attached.append($0) }
        fixture.pasteboard.declareTypes([.string, .png], owner: nil)
        fixture.pasteboard.setString("text", forType: .string)
        fixture.pasteboard.setData(pngBytes, forType: .png)
        fixture.view.paste(nil)
        #expect(attached == [[AttachableImage(data: pngBytes, mimeType: "image/png")]])
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.sink.inputBytes.isEmpty)
    }

    // 画像が無ければ、テキストをペーストする。
    @Test func commandVPastesTextWhenThereIsNoImage() async throws {
        let fixture = try await makeFixture()
        var attached = 0
        fixture.view.imageAttachHandler = { _ in attached += 1 }
        fixture.pasteboard.setString("echo hi", forType: .string)
        fixture.view.paste(nil)
        #expect(try await sentText(fixture.sink) == "echo hi")
        #expect(attached == 0)
    }

    // 画像を扱わない（ハンドラが無い）ときは、テキストだけをペーストする。
    @Test func withoutAHandlerOnlyTextIsPasted() async throws {
        let fixture = try await makeFixture()
        fixture.pasteboard.declareTypes([.string, .png], owner: nil)
        fixture.pasteboard.setString("plain", forType: .string)
        fixture.pasteboard.setData(pngBytes, forType: .png)
        fixture.view.paste(nil)
        #expect(try await sentText(fixture.sink) == "plain")
    }

    // Scenario: Drop highlight / Unsupported file
    @Test func droppedImagesAreAttachedAndOtherFilesIgnored() async throws {
        let fixture = try await makeFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("a b.png")
        let text = directory.appendingPathComponent("notes.txt")
        try pngBytes.write(to: png)
        try Data("notes".utf8).write(to: text)
        var attached: [[AttachableImage]] = []
        fixture.view.imageAttachHandler = { attached.append($0) }

        let drag = pasteboard()
        drag.writeObjects([png as NSURL, text as NSURL])
        #expect(fixture.view.dragOperation(for: drag) == .copy)
        #expect(fixture.view.isDropFrameVisible)
        #expect(fixture.view.dropFiles(from: drag))
        #expect(attached.map { $0.map(\.mimeType) } == [["image/png"]])

        // テキストだけなら何も添付しない。
        let onlyText = pasteboard()
        onlyText.writeObjects([text as NSURL])
        #expect(!fixture.view.dropFiles(from: onlyText))
        #expect(attached.count == 1)

        // ファイルを運ばないドラッグ（タブの並べ替え）は受け付けず、枠を消す。
        let tabDrag = pasteboard()
        tabDrag.setString("s1", forType: .string)
        #expect(fixture.view.dragOperation(for: tabDrag) == [])
        #expect(!fixture.view.isDropFrameVisible)
    }
}

// MARK: - 補助

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
private let webpBytes = Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)

private func pasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("Tabghostty.tests.\(UUID().uuidString)"))
    board.clearContents()
    return board
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("TabghosttyImageAttach-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 1×1 の TIFF（macOS のスクリーンショットは TIFF で pasteboard に載る）。
private func tiffBytes() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    return try #require(bitmap.tiffRepresentation)
}
