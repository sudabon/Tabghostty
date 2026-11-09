import AppKit
import UniformTypeIdentifiers

/// 添付する画像 1 つ（pasteboard やドロップしたファイルから読んだもの）。
public struct AttachableImage: Equatable, Sendable {
    /// 画像のバイト列（デーモンにそのまま送る）。
    public var data: Data
    /// `image/png` など。
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// 画像の添付（webtabinal `web/src/image-attach.ts` の移植。spec: image-attach、phase4 design D5）。
///
/// エージェント（Claude Code、Codex、cursor-agent）は画像をパスで受け取る。そこで、画像をデーモンに保存させ、
/// 返ってきたパスを、ネイティブの端末にファイルをドロップしたときと同じ形でセッションに入力する。
public enum ImageAttach {
    /// 添付できる形式（どのエージェントも読めるもの）。SVG はスクリプトを含められるので対象外。
    public static let attachableMIMETypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// 添付できる形式か（パラメータと大文字小文字は無視する）。
    public static func isAttachableImageType(_ type: String?) -> Bool {
        guard let type, let base = type.split(separator: ";", omittingEmptySubsequences: false).first else { return false }
        return attachableMIMETypes.contains(base.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// `UTType` から、添付できる形式の MIME タイプを求める。添付できなければ nil。
    public static func mimeType(for type: UTType) -> String? {
        let candidates: [(UTType, String)] = [(.png, "image/png"), (.jpeg, "image/jpeg"), (.gif, "image/gif"), (.webP, "image/webp")]
        return candidates.first { type.conforms(to: $0.0) }?.1
    }

    /// ファイルの先頭のバイト列から形式を求める（拡張子が無い・違うファイルのため）。添付できなければ nil。
    public static func sniffMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }

    // MARK: - パスの入力

    /// シェル（と、ドロップしたパスをシェルのように読むエージェントの入力欄）が区切りとみなす文字。
    /// デーモンが作るファイル名には含まれないが、ディレクトリには含まれうる（`~/Library/Application Support/...`）。
    private static let charactersToEscape: Set<Unicode.Scalar> = [
        " ", "\t", "\n", "\"", "'", "\\", "$", "`", "&", "|", ";", "<", ">", "(", ")", "*", "?", "[", "]", "{", "}", "!", "#",
    ]

    /// ファイルをドロップしたときの端末と同じく、バックスラッシュでエスケープする。
    ///
    /// Web 版の正規表現（`/[ \t\n"'\\$`&|;<>()*?[\]{}!#]/g`）と同じく、Unicode スカラーを 1 つずつ見る
    /// （書記素で見ると、CR LF や、スペースのあとの結合文字を 1 つの文字として扱ってしまう）。
    public static func escapeTerminalPath(_ path: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if charactersToEscape.contains(scalar) {
                escaped.append("\\")
            }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    /// 保存した画像のパスから、セッションに入力するテキストを作る。スペースで区切り、続けて入力した文字が
    /// 最後のパスにつながらないよう、末尾にもスペースを付ける。使えるパスが無ければ空。
    public static func terminalText(forPaths paths: [String]) -> String {
        let usable = paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return "" }
        return usable.map(escapeTerminalPath).joined(separator: " ") + " "
    }

    // MARK: - pasteboard とドロップ

    /// pasteboard の画像（PNG、無ければ TIFF を PNG にしたもの）。画像が無ければ nil（テキストのペーストに進む）。
    /// macOS のスクリーンショットは TIFF で届くので、デーモンに保存する形式を PNG にそろえる。
    public static func pastedImage(from pasteboard: NSPasteboard) -> AttachableImage? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return AttachableImage(data: png, mimeType: "image/png")
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return AttachableImage(data: png, mimeType: "image/png")
    }

    /// ドラッグがファイルを運んでいるか（運んでいなければ、端末はドロップを受け付けない）。
    public static func dragCarriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(.fileURL) ?? false
    }

    /// ドロップしたファイルの URL。
    public static func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { ($0 as? NSURL)?.filePathURL }
    }

    /// ファイルを読む。形式はファイルの種類（`UTType`）か、分からなければ中身から決める。添付できない形式なら nil。
    public static func attachableImage(at url: URL) -> AttachableImage? {
        let declared = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        // 添付できる画像の種類なら、その種類で決める。
        if let declared, let mime = mimeType(for: declared) {
            return readImage(at: url, mimeType: mime)
        }
        // 種類が分からないファイル（拡張子が無い、macOS が知らない拡張子で動的な種類になった、ただのデータ）は中身で決める。
        // 種類の分かる、添付できないファイル（テキスト、PDF、SVG など）は添付しない。
        let unknownType = declared.map { $0.isDynamic || $0 == .data || $0 == .item } ?? true
        guard unknownType, let data = try? Data(contentsOf: url, options: .mappedIfSafe), let mime = sniffMIMEType(data) else {
            return nil
        }
        return AttachableImage(data: data, mimeType: mime)
    }

    private static func readImage(at url: URL, mimeType: String) -> AttachableImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        return AttachableImage(data: data, mimeType: mimeType)
    }

    /// ドロップしたファイルのうち、添付できる画像（順序はそのまま）。
    public static func attachableImages(at urls: [URL]) -> [AttachableImage] {
        urls.compactMap(attachableImage(at:))
    }
}
