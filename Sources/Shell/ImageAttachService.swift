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
        for image in images {
            do {
                let saved = try await uploader.uploadImage(sessionID: sid, data: image.data, mimeType: image.mimeType)
                paths.append(saved.path)
            } catch {
                Self.log.warning("Image attach failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let text = ImageAttach.terminalText(forPaths: paths)
        // アップロードの間にタブを切り替えたら、パスはそのセッションのものなので入力しない。
        guard !text.isEmpty, store.activeSessionID == sid else { return nil }
        paste(text)
        return text
    }
}
