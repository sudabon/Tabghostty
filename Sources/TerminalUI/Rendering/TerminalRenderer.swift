import AppKit
import os
import TerminalCore

/// 描画の実装の種類（環境変数 `TABGHOSTTY_RENDERER`。phase5 design D1）。
public enum TerminalRendererKind: String, Sendable, CaseIterable {
    /// Phase 1 の Core Text / Core Graphics による描画。比較とデバッグ、Metal が使えないときの退避先。
    case coreText = "coretext"
    /// Metal による描画（既定）。
    case metal

    /// 環境変数の名前。
    public static let environmentKey = "TABGHOSTTY_RENDERER"

    /// 環境変数から決める。未設定なら Metal。知らない値ならログを出して Metal にする。
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalRendererKind {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .metal
        }
        switch raw.lowercased() {
        case "coretext", "core-text", "core_text", "cg": return .coreText
        case "metal": return .metal
        default:
            RenderLog.logger.warning("\(environmentKey, privacy: .public)=\(raw, privacy: .public) は知らない値なので、Metal で描きます")
            return .metal
        }
    }
}

/// 描画のログ（`log stream --predicate 'subsystem == "Tabghostty" && category == "render"'`）。
enum RenderLog {
    static let logger = Logger(subsystem: "Tabghostty", category: "render")
}

/// `TerminalView` の描画の実装（phase5 design D1）。
///
/// ビューは描画のモデル（セル、選択、カーソル、IME の未確定の文字列、検索の強調、リンク、画像）を持ち、
/// 変わったところを `invalidate…` で知らせる。実装は、そのモデルを読んで描く。
///
/// - `CoreTextRenderer`: ビューの `draw(_:)` で、変わった矩形だけを Core Graphics で描く。
/// - `MetalRenderer`: サブビューの `CAMetalLayer` に、display link の tick ごとに（変化があるときだけ）描く。
@MainActor
protocol TerminalRenderer: AnyObject {
    var kind: TerminalRendererKind { get }

    /// ビューに組み込む（必要ならサブビューやレイヤーを置く）。
    func install(in view: TerminalView)
    /// ビューから外す。
    func uninstall()

    /// 全体を描き直す（配色・フォント・グリッドの大きさが変わったなど）。
    func invalidateAll()
    /// 行の内容（セル・選択・検索の強調）が変わった。
    func invalidateRows(_ rows: IndexSet)
    /// 行の内容に依らないもの（カーソル・IME・リンクの下線・画像）が変わった矩形（ビューの座標）。
    func invalidate(_ rect: NSRect)
    /// ビューの大きさ・画面の倍率・セルの寸法が変わった。
    func layoutChanged()

    /// 中身（テクスチャ・画像）を持っている画像の世代。スナップショットでは、これ以外の画像の中身だけをもらう。
    var knownImageGenerations: Set<UInt64> { get }
    /// 画像の配置と、新しく届いた中身を受け取る。配置で使わなくなった中身は捨てる（phase5 design D7）。
    func updateImages(_ placements: [ImagePlacement], pixels: [UInt64: ImagePixels])

    /// 描くものができたときに呼ぶ（ビューが、止めていた display link を再開する）。
    var onNeedsFrame: (() -> Void)? { get set }

    /// まだ画面に出していない変化があるか（display link を止めてよいかの判定に使う）。
    var needsFrame: Bool { get }
    /// display link の tick。変化があれば描いて true を返す。ビューの `draw(_:)` で描く実装は何もしない。
    @discardableResult
    func renderFrameIfNeeded() -> Bool
}
