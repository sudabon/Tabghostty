import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: inline-images「Kitty graphics protocol」、phase5 design D7（画像のパイプライン）。
@MainActor
@Suite struct InlineImageTests {
    private static let context: MetalRenderContext? = try? MetalRenderContext()

    private func solid(_ rgb: (UInt8, UInt8, UInt8), width: Int, height: Int) -> [UInt8] {
        var pixels: [UInt8] = []
        for _ in 0..<(width * height) { pixels += [rgb.0, rgb.1, rgb.2, 255] }
        return pixels
    }

    private func kitty(_ control: String, _ payload: [UInt8]) -> String {
        "\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\"
    }

    private func makeView(_ kind: TerminalRendererKind, output: String) async throws -> (TerminalView, TerminalController) {
        let context = try #require(Self.context)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: kind) { $0(context) }
        view.frame = NSRect(x: 0, y: 0, width: 2 * GridGeometry.padding + 30 * view.metrics.width, height: 2 * GridGeometry.padding + 6 * view.metrics.height)
        let controller = try TerminalController(sid: "s1", cols: 30, rows: 6, maxScrollback: 100, colors: Palette.dark.terminalColors, sink: RecordingSink())
        await controller.setViewGrid(.init(cols: 30, rows: 6, cellWidthPx: view.metrics.widthPx, cellHeightPx: view.metrics.heightPx))
        await controller.attach()
        await controller.receiveReplay(Array(output.utf8), done: true)
        view.controller = controller
        try await refresh(view, controller)
        return (view, controller)
    }

    /// ビューが持っている画像の世代を渡してスナップショットを取り、反映する（display link の代わり）。
    private func refresh(_ view: TerminalView, _ controller: TerminalController) async throws {
        view.apply(try #require(await controller.makeSnapshot(forceFull: true, knownImageGenerations: view.renderer.knownImageGenerations)))
    }

    private func render(_ view: TerminalView) throws -> [UInt8] {
        let scale = view.metrics.scale
        let width = Int((view.bounds.width * scale).rounded())
        let height = Int((view.bounds.height * scale).rounded())
        let image: CGImage
        if let metal = view.renderer as? MetalRenderer {
            let rendered = try #require(metal.renderOffscreen())
            image = try #require(rendered.cgImage)
        } else {
            // sRGB のまま描く（色空間の変換で暗い色が丸められないように）。
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
            )?.retagging(with: .sRGB))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            image = try #require(rep.cgImage)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// ビューの座標の点のピクセル（上が 0）。
    private func pixel(_ pixels: [UInt8], _ view: TerminalView, at point: CGPoint) -> (Int, Int, Int) {
        let scale = view.metrics.scale
        let width = Int((view.bounds.width * scale).rounded())
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        let index = (y * width + x) * 4
        return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
    }

    private func isClose(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 12) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    // Scenario: Agent screenshot preview — カーソルの位置に、セルに合った大きさで描く（Core Text と Metal で同じ）。
    @Test(arguments: TerminalRendererKind.allCases)
    func imageIsDrawnAtItsPlacement(renderer: TerminalRendererKind) async throws {
        let red = solid((230, 20, 20), width: 8, height: 8)
        let (view, _) = try await makeView(renderer, output: "ab" + kitty("a=T,f=32,s=8,v=8,i=1,c=4,r=2", red))
        #expect(view.activeRenderer == renderer)
        let placement = try #require(view.images.first)
        // セルの数で指定した大きさは、倍率に関係なくセルの大きさに合う（Retina でも非 Retina でも同じ見た目）。
        let rect = view.imageRect(placement)
        #expect(abs(rect.width - 4 * view.metrics.width) < 0.01)
        #expect(abs(rect.height - 2 * view.metrics.height) < 0.01)
        #expect(abs(rect.minX - view.cellRect(x: 2, y: 0).minX) < 0.01)
        #expect(view.renderer.knownImageGenerations == [placement.generation])

        let pixels = try render(view)
        let center = pixel(pixels, view, at: CGPoint(x: rect.midX, y: rect.midY))
        #expect(isClose(center, (230, 20, 20)), "画像の中のピクセル \(center)")
        // 画像の外は背景のまま。
        let outside = view.cellRect(x: 10, y: 3)
        #expect(isClose(pixel(pixels, view, at: CGPoint(x: outside.midX, y: outside.midY)), (30, 30, 30)))
    }

    // z の値で層を分ける。z < 0 は文字より下（文字が見える）、z ≥ 0 は文字より上（文字を隠す）。
    @Test(arguments: TerminalRendererKind.allCases)
    func layersFollowZ(renderer: TerminalRendererKind) async throws {
        let blue = solid((20, 20, 230), width: 4, height: 4)
        let text = String(repeating: "█", count: 8)
        let below = try await makeView(renderer, output: "\u{1b}[s" + kitty("a=T,f=32,s=4,v=4,i=1,c=8,r=1,z=-1", blue) + "\u{1b}[u" + text)
        let above = try await makeView(renderer, output: "\u{1b}[s" + kitty("a=T,f=32,s=4,v=4,i=1,c=8,r=1,z=1", blue) + "\u{1b}[u" + text)
        let probe = below.0.cellRect(x: 3, y: 0)
        let point = CGPoint(x: probe.midX, y: probe.midY)
        // 文字より下: ブロック文字（前景色 #cccccc）が上に見える。文字より上: 画像の色。
        #expect(isClose(pixel(try render(below.0), below.0, at: point), (204, 204, 204), tolerance: 30))
        let covered = pixel(try render(above.0), above.0, at: point)
        #expect(isClose(covered, (20, 20, 230)), "画像の中のピクセル \(covered)")
    }

    // 削除した画像のテクスチャは手放す。
    @Test(arguments: TerminalRendererKind.allCases)
    func deletedImagesReleaseTheirTextures(renderer: TerminalRendererKind) async throws {
        let (view, controller) = try await makeView(renderer, output: kitty("a=T,f=32,s=2,v=2,i=5", solid((1, 2, 3), width: 2, height: 2)))
        #expect(view.renderer.knownImageGenerations.count == 1)
        await controller.receiveOutput(Array("\u{1b}_Ga=d,d=A\u{1b}\\".utf8))
        try await refresh(view, controller)
        #expect(view.images.isEmpty)
        #expect(view.renderer.knownImageGenerations.isEmpty)
    }

    // 裏のタブの画像はテクスチャを作らず、表示したときに作る（切り替えると前のタブのテクスチャは手放す）。
    @Test func backgroundSessionsCreateTexturesWhenShown() async throws {
        let (view, first) = try await makeView(.metal, output: kitty("a=T,f=32,s=2,v=2,i=5", solid((9, 9, 9), width: 2, height: 2)))
        let generation = try #require(view.images.first?.generation)
        let second = try TerminalController(sid: "s2", cols: 30, rows: 6, maxScrollback: 100, colors: nil, sink: RecordingSink())
        await second.attach()
        await second.receiveReplay(Array("other".utf8), done: true)
        view.controller = second
        try await refresh(view, second)
        #expect(view.renderer.knownImageGenerations.isEmpty)
        // 戻ると、中身をもらい直してテクスチャを作る。
        view.controller = first
        try await refresh(view, first)
        #expect(view.renderer.knownImageGenerations == [generation])
    }

    // Scenario: Scrolled away — スクロールバックに戻ると、元の位置に描く。
    @Test func imagesFollowTheViewportIntoScrollback() async throws {
        let output = "top\r\n" + kitty("a=T,f=32,s=2,v=2,i=7", solid((5, 6, 7), width: 2, height: 2))
            + (0..<20).map { "\r\nline \($0)" }.joined()
        let (view, controller) = try await makeView(.metal, output: output)
        #expect(view.images.isEmpty)
        // いちばん上までスクロールする（スクロールバックに戻る）。
        controller.enqueueScroll(ScrollInput(lines: 100, x: 10, y: 10, modifiers: [], surface: view.mouseSurface))
        await controller.flushInput()
        try await refresh(view, controller)
        let placement = try #require(view.images.first)
        #expect(placement.row == 1)
        #expect(view.renderer.knownImageGenerations == [placement.generation])
    }
}
