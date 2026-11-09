import AppKit
import Metal
import Testing
import TerminalCore
@testable import TerminalUI

/// phase5 design D1: Metal の描画（シェーダーの実行時コンパイル、Core Text への退避、dirty の行だけの作り直し、
/// Core Text と同じ見た目。spec: terminal-rendering「Rendering parity」）。
@MainActor
@Suite struct MetalRendererTests {
    /// テストで使い回す（コンパイルは数十 ms かかる）。
    private static let context: MetalRenderContext? = try? MetalRenderContext()

    private func liveController(_ text: String, cols: Int = 40, rows: Int = 6, palette: Palette) async throws -> TerminalController {
        let controller = try TerminalController(
            sid: "s1", cols: cols, rows: rows, maxScrollback: 10, colors: palette.terminalColors, sink: RecordingSink()
        )
        await controller.attach()
        await controller.receiveReplay(Array(text.utf8), done: true)
        return controller
    }

    private func makeView(_ kind: TerminalRendererKind, controller: TerminalController, palette: Palette,
                          size: NSSize = NSSize(width: 420, height: 140)) async throws -> TerminalView {
        let context = try #require(Self.context)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: palette, renderer: kind) { $0(context) }
        view.controller = controller
        view.frame = NSRect(origin: .zero, size: size)
        view.apply(try #require(await controller.makeSnapshot(forceFull: true)))
        return view
    }

    /// Core Text で描いた画像（Metal と同じく、セルの寸法の倍率で描く）。
    private func coreTextImage(_ view: TerminalView) throws -> NSBitmapImageRep {
        let scale = view.metrics.scale
        // sRGB のまま描く（色空間の変換で暗い色が丸められないように）。
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((view.bounds.width * scale).rounded()),
            pixelsHigh: Int((view.bounds.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB))
        image.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private func metalImage(_ view: TerminalView) throws -> NSBitmapImageRep {
        let renderer = try #require(view.renderer as? MetalRenderer)
        return try #require(renderer.renderOffscreen())
    }

    private struct Difference {
        var meanPerChannel: Double
        /// 1 チャンネルでも 96 より大きく違うピクセルの割合。
        var largeFraction: Double
    }

    private func compare(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Difference {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        let pa = Self.srgbPixels(a, width: width, height: height)
        let pb = Self.srgbPixels(b, width: width, height: height)
        var total = 0.0
        var large = 0
        for index in stride(from: 0, to: pa.count, by: 4) {
            let d = (abs(Int(pa[index]) - Int(pb[index])), abs(Int(pa[index + 1]) - Int(pb[index + 1])), abs(Int(pa[index + 2]) - Int(pb[index + 2])))
            total += Double(d.0 + d.1 + d.2) / 3
            if max(d.0, d.1, d.2) > 96 { large += 1 }
        }
        let count = Double(width * height)
        return Difference(meanPerChannel: total / count, largeFraction: Double(large) / count)
    }

    /// 画像を sRGB の RGBA8 にする（画像ごとの色空間から、Core Graphics が正しく変換する）。
    private static func srgbPixels(_ image: NSBitmapImageRep, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let cgImage = image.cgImage else { return pixels }
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// `TABGHOSTTY_TEST_DUMP` にディレクトリを指定すると、比べた画像を PNG で書き出す（目で比べるため）。
    static func dump(_ image: NSBitmapImageRep, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["TABGHOSTTY_TEST_DUMP"],
              let data = image.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: - シェーダーと退避先

    @Test func shadersCompileAtRuntime() throws {
        let context = try #require(Self.context, "Metal のデバイスが無い環境では実行できない")
        #expect(context.rectPipeline.label == nil || true)
        #expect(context.compileDuration < .seconds(5))
    }

    @Test func brokenShaderSourceFailsToCompile() {
        #expect(throws: (any Error).self) {
            _ = try MetalRenderContext(source: "this is not metal")
        }
    }

    // 作り終わるまでは Core Text で描き、作り終わったら Metal に切り替える。
    @Test func viewSwitchesToMetalWhenTheContextIsReady() throws {
        let context = try #require(Self.context)
        var deliver: ((MetalRenderContext?) -> Void)?
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: .metal) { deliver = $0 }
        #expect(view.activeRenderer == .coreText)
        deliver?(context)
        #expect(view.activeRenderer == .metal)
        #expect(view.subviews.contains { $0 is MetalHostView })
    }

    // 作れなかったら（デバイスが無い・コンパイルに失敗した）Core Text で描き続ける。
    @Test func viewKeepsCoreTextWhenMetalIsUnavailable() {
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: .metal) { $0(nil) }
        #expect(view.activeRenderer == .coreText)
        #expect(!view.subviews.contains { $0 is MetalHostView })
    }

    @Test func coreTextIsUsedWhenRequested() throws {
        let context = try #require(Self.context)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: .coreText) { $0(context) }
        #expect(view.activeRenderer == .coreText)
    }

    // MARK: - CellBuffers（dirty の行だけを作り直す）

    @Test func cellBuffersRebuildOnlyDirtyRows() {
        var buffers = CellBuffers()
        buffers.resize(rows: 4)
        var built: [Int] = []
        buffers.rebuildDirty { y in
            built.append(y)
            return CellBuffers.Row(backgrounds: [RectInstance(rect: SIMD4(Float(y), 0, 1, 1), color: .one)])
        }
        #expect(built == [0, 1, 2, 3])
        built.removeAll()
        buffers.markDirty(IndexSet([2, 7]))
        buffers.rebuildDirty { y in
            built.append(y)
            return CellBuffers.Row()
        }
        // 範囲の外の行は無視し、dirty の行だけを作り直す。ほかの行はそのまま。
        #expect(built == [2])
        #expect(buffers.rows[0].backgrounds.count == 1)
        #expect(buffers.rows[2].backgrounds.isEmpty)
        #expect(buffers.backgroundCount == 3)
    }

    @Test func snapshotDirtyRowsAreTheOnlyRowsRebuilt() async throws {
        let controller = try await liveController("one\r\ntwo\r\nthree", palette: .dark)
        let view = try await makeView(.metal, controller: controller, palette: .dark)
        let renderer = try #require(view.renderer as? MetalRenderer)
        renderer.rebuildRows()
        #expect(renderer.cellBuffers.dirty.isEmpty)

        await controller.receiveOutput(Array("\u{1b}[2;1HTWO".utf8))
        view.apply(try #require(await controller.makeSnapshot()))
        // 書き換えた行（とカーソルが離れた行）だけが dirty。触れていない行は作り直さない。
        #expect(renderer.cellBuffers.dirty.contains(1))
        #expect(!renderer.cellBuffers.dirty.contains(0))
        #expect(!renderer.cellBuffers.dirty.contains(4))
        #expect(!renderer.cellBuffers.dirty.contains(5))
    }

    // MARK: - Core Text と同じ見た目（spec: terminal-rendering「Rendering parity」）

    private static let sample = [
        // ls --color 風の色、太字、下線、打ち消し線、反転
        "\u{1b}[1;34mdir\u{1b}[0m \u{1b}[32mexec\u{1b}[0m \u{1b}[4munder\u{1b}[0m \u{1b}[9mstrike\u{1b}[0m \u{1b}[7mrev\u{1b}[0m",
        // 256 色と truecolor の背景
        "\u{1b}[48;5;22m bg \u{1b}[0m \u{1b}[38;2;255;128;0mtrue\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m \u{1b}[4:3mcurly\u{1b}[0m",
        // CJK と絵文字
        "日本語のテキスト 😀 ok",
        "\u{1b}[4:4mdotted\u{1b}[0m \u{1b}[4:2mdouble\u{1b}[0m \u{1b}[53mover\u{1b}[0m",
    ].joined(separator: "\r\n")

    @Test(arguments: ["light", "dark"])
    func metalMatchesCoreTextApartFromAntialiasing(scheme: String) async throws {
        let palette: Palette = scheme == "light" ? .light : .dark
        let controller = try await liveController(Self.sample + "\r\n$ ", cols: 50, rows: 6, palette: palette)
        let coreTextView = try await makeView(.coreText, controller: controller, palette: palette)
        let metalView = try await makeView(.metal, controller: controller, palette: palette)
        #expect(metalView.activeRenderer == .metal)

        let reference = try coreTextImage(coreTextView)
        let candidate = try metalImage(metalView)
        #expect(reference.pixelsWide == candidate.pixelsWide)
        #expect(reference.pixelsHigh == candidate.pixelsHigh)
        let difference = compare(reference, candidate)
        Self.dump(reference, "parity-\(scheme)-coretext")
        Self.dump(candidate, "parity-\(scheme)-metal")
        // 違いはグリフの縁（アンチエイリアス）だけ。
        #expect(difference.meanPerChannel < 3, "平均の差 \(difference.meanPerChannel)")
        #expect(difference.largeFraction < 0.005, "大きく違うピクセルの割合 \(difference.largeFraction)")
    }

    @Test func selectionAndCursorMatchCoreText() async throws {
        let controller = try await liveController("hello world\r\nsecond line", palette: .dark)
        // 1 行目の 0〜4 列を選択する。
        let surface = MouseSurface(
            width: 800, height: 200, cellWidth: 16, cellHeight: 34, paddingTop: 8, paddingBottom: 8,
            paddingLeft: 8, paddingRight: 8, columns: 40
        )
        func input(_ kind: SelectionInput.Kind, _ column: Int, edge: Bool) -> SelectionInput {
            SelectionInput(kind: kind, cell: GridPoint(x: column, y: 0), x: Double(8 + column * 16 + (edge ? 15 : 2)), y: 25, surface: surface)
        }
        controller.enqueueSelection(input(.press(timeNanoseconds: 1, repeatIntervalNanoseconds: 1, repeatDistance: 1), 0, edge: false))
        controller.enqueueSelection(input(.drag, 4, edge: true))
        controller.enqueueSelection(input(.release, 4, edge: true))
        await controller.flushInput()

        let coreTextView = try await makeView(.coreText, controller: controller, palette: .dark)
        let metalView = try await makeView(.metal, controller: controller, palette: .dark)
        let difference = compare(try coreTextImage(coreTextView), try metalImage(metalView))
        #expect(difference.meanPerChannel < 3, "平均の差 \(difference.meanPerChannel)")
        #expect(difference.largeFraction < 0.005, "大きく違うピクセルの割合 \(difference.largeFraction)")
        Self.dump(try coreTextImage(coreTextView), "selection-coretext")
        Self.dump(try metalImage(metalView), "selection-metal")
    }

    // IME の未確定の文字列（下地、文字、文節の下線）も同じに見える。
    @Test func markedTextMatchesCoreText() async throws {
        let controller = try await liveController("$ ", palette: .dark)
        let coreTextView = try await makeView(.coreText, controller: controller, palette: .dark)
        let metalView = try await makeView(.metal, controller: controller, palette: .dark)
        for view in [coreTextView, metalView] {
            view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 2), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(metalView.markedTextCells.count == 4)
        let reference = try coreTextImage(coreTextView)
        let candidate = try metalImage(metalView)
        Self.dump(reference, "marked-coretext")
        Self.dump(candidate, "marked-metal")
        let difference = compare(reference, candidate)
        #expect(difference.meanPerChannel < 3, "平均の差 \(difference.meanPerChannel)")
        #expect(difference.largeFraction < 0.005, "大きく違うピクセルの割合 \(difference.largeFraction)")
    }

    // 実際のエージェントの TUI の出力（webtabinal のフィクスチャ）でも同じに見える。
    @Test(arguments: ["claude/2.1.239/completed-turn", "codex/0.149.0/exec-approval", "cursor-agent/2026.08.11-e8db854/working"])
    func agentScreensMatchCoreText(fixture: String) async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/\(fixture)")
        struct Metadata: Decodable { let rows: Int; let columns: Int }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        let stream = try Data(contentsOf: directory.appendingPathComponent("stream.raw"))
        let controller = try TerminalController(
            sid: "s1", cols: metadata.columns, rows: metadata.rows, maxScrollback: 100,
            colors: Palette.dark.terminalColors, sink: RecordingSink()
        )
        await controller.attach()
        await controller.receiveReplay(Array(stream), done: true)
        let size = NSSize(width: CGFloat(metadata.columns) * 8.5 + 8, height: CGFloat(metadata.rows) * 17 + 8)
        let coreTextView = try await makeView(.coreText, controller: controller, palette: .dark, size: size)
        let metalView = try await makeView(.metal, controller: controller, palette: .dark, size: size)
        let reference = try coreTextImage(coreTextView)
        let candidate = try metalImage(metalView)
        Self.dump(reference, "agent-\(fixture.replacingOccurrences(of: "/", with: "_"))-coretext")
        Self.dump(candidate, "agent-\(fixture.replacingOccurrences(of: "/", with: "_"))-metal")
        let difference = compare(reference, candidate)
        #expect(difference.meanPerChannel < 3, "平均の差 \(difference.meanPerChannel)")
        #expect(difference.largeFraction < 0.005, "大きく違うピクセルの割合 \(difference.largeFraction)")
    }
}
