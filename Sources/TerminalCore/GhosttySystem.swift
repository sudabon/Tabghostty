import CoreGraphics
import Foundation
import GhosttyVt
import ImageIO

/// libghostty-vt のプロセス全体の設定（`ghostty_sys_set`。Sources/TerminalCore/README.md の対応表）。
///
/// libghostty-vt は PNG を自分では展開しない。PNG の展開を渡すと、Kitty Graphics の PNG（`f=100`）を受け付ける
/// （spec: inline-images「Kitty graphics protocol」。`kitten icat` は PNG で送る）。
///
/// `ghostty_sys_set` はスレッドセーフではなく、ほかのスレッドがライブラリを使い始める前に呼ぶ。アプリの起動時に
/// `install()` を呼び、念のため最初の `VTTerminal` を作るときにも呼ぶ（2 回目以降は何もしない）。
public enum GhosttySystem {
    private static let installed: Bool = {
        let result = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decodePNG, to: UnsafeRawPointer.self))
        return result == GHOSTTY_SUCCESS
    }()

    /// PNG の展開を libghostty-vt に渡す。渡せたら true。
    @discardableResult
    public static func install() -> Bool {
        installed
    }

    /// リンクしている libghostty-vt のバージョン（`ghostty_version()`。開発版のビルドなら "1.1.0-dev+abc1234" のような形）。
    /// デーモンが生成した画面との一致検証で、生成に使ったバージョンと照合する（phase6 design D5）。
    public static var libraryVersion: String {
        String(cString: ghostty_version())
    }

    /// PNG のバイト列を、straight alpha の RGBA8（sRGB、上の行から順）にする。
    static func decodeToRGBA(_ data: Data) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard draw(image, into: &pixels) else { return nil }
        return (image.width, image.height, pixels)
    }

    /// `image` を sRGB の RGBA8 にして `pixels`（幅 × 高さ × 4 バイト）に書く。
    fileprivate static func draw(_ image: CGImage, into pixels: UnsafeMutableRawBufferPointer) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              let context = CGContext(
                  data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Core Graphics は premultiplied でしか描けないので、straight alpha に戻す（Kitty Graphics の RGBA）。
        let bytes = pixels.bindMemory(to: UInt8.self)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return true
    }

    fileprivate static func draw(_ image: CGImage, into pixels: inout [UInt8]) -> Bool {
        pixels.withUnsafeMutableBytes { draw(image, into: $0) }
    }
}

/// `GhosttySysDecodePngFn`。ライブラリのアロケータで確保したバッファに RGBA を書いて渡す（ライブラリが解放する）。
private let decodePNG: GhosttySysDecodePngFn = { _, allocator, data, length, out in
    guard let data, length > 0, let out else { return false }
    let png = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: length, deallocator: .none)
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0, image.width <= Int(UInt32.max), image.height <= Int(UInt32.max) else { return false }
    let (count, overflow) = image.width.multipliedReportingOverflow(by: image.height * 4)
    // 大きすぎる画像は、ライブラリのアロケータが NULL を返す（失敗として扱う）。
    guard !overflow, let buffer = ghostty_alloc(allocator, count) else { return false }
    guard GhosttySystem.draw(image, into: UnsafeMutableRawBufferPointer(start: buffer, count: count)) else {
        ghostty_free(allocator, buffer, count)
        return false
    }
    out.pointee = GhosttySysImage(width: UInt32(image.width), height: UInt32(image.height), data: buffer, data_len: count)
    return true
}
