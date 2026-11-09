import DaemonClient
import Foundation
import os
import TerminalUI

/// ペーストした・ドロップした画像をアクティブなセッションに添付する（spec: image-attach「Upload and type paths」、
/// phase4 design D5。webtabinal `TerminalView.tsx` の `attachImages` の移植）。
///
/// 1. 始めたときのアクティブなセッションに、画像を 1 つずつ順に `POST /api/sessions/{id}/images` で送る。
///    失敗した画像（10 MiB を超える、対応していない形式など）は飛ばす。
/// 2. 返ってきたパスをエスケープし、スペースで区切って末尾にもスペースを付ける。
/// 3. アップロードの間にアクティブなセッションが変わっていなければ、通常のペーストの経路で入力する
///    （bracketed paste を含む。live でなければ何もしない）。成功した画像が無ければ何も入力しない。
@MainActor
public final class ImageAttachService {
    private let store: SessionStore
    private let uploader: any ImageUploadAPI
    private let paste: (String) -> Void
    private static let log = Logger(subsystem: "com.tabghostty.app", category: "image-attach")
    /// 添付できなかった画像があった・入力しなかったことを知らせる（トーストに出す）。
    public var onFailure: ((String) -> Void)?

    /// - Parameter paste: アクティブなセッションにテキストをペーストする（`TerminalView.pasteText`）
    public init(store: SessionStore, uploader: any ImageUploadAPI, paste: @escaping (String) -> Void) {
        self.store = store
        self.uploader = uploader
        self.paste = paste
    }

    /// 画像を添付する。入力したテキストを返す（入力しなかったら nil）。
    @discardableResult
    public func attach(_ images: [AttachableImage]) async -> String? {
        guard let sid = store.activeSessionID, !images.isEmpty else { return nil }
        var paths: [String] = []
        var failures: [String] = []
        for image in images {
            do {
                let saved = try await uploader.uploadImage(sessionID: sid, data: image.data, mimeType: image.mimeType)
                paths.append(saved.path)
            } catch {
                Self.log.warning("Image attach failed: \(error.localizedDescription, privacy: .public)")
                failures.append(ConfigEditor.message(for: error))
            }
        }
        // 失敗した画像は飛ばすが、黙って捨てない（ペーストしても何も起きないように見えるため）。
        if let reason = failures.first {
            let count = images.count == 1 ? "The image" : "\(failures.count) of \(images.count) images"
            onFailure?("\(count) could not be attached: \(reason)")
        }
        let text = ImageAttach.terminalText(forPaths: paths)
        guard !text.isEmpty else { return nil }
        // アップロードの間にタブを切り替えたら、パスはそのセッションのものなので入力しない。
        guard store.activeSessionID == sid else {
            onFailure?("The image paths were not typed because the active tab changed during the upload.")
            return nil
        }
        paste(text)
        return text
    }
}
