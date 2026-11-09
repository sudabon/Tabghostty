import AppKit
import TerminalCore

/// コピーとペースト（spec: terminal-clipboard、phase2 design D4）。
///
/// Edit メニューの Copy / Paste は first responder に送られるので、端末にフォーカスがあるときだけここに届く
/// （テキストフィールドにフォーカスがあれば、フィールドの標準のコピーとペーストになる）。
extension TerminalView: @preconcurrency NSMenuItemValidation {
    /// 選択範囲を plain テキストでコピーする。選択が空なら何もしない。セッションには何も送らない（Command-C で SIGINT を送らない）。
    @objc public func copy(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        copySelectionToPasteboard()
    }

    /// Command-V（spec: terminal-clipboard「Paste with Command-V」）。
    ///
    /// pasteboard に画像（PNG、または PNG にした TIFF）があれば、テキストより優先して `imageAttachHandler` に渡す
    /// （phase4 design D5）。無ければテキストをペーストする。
    @objc public func paste(_ sender: Any?) {
        guard controller != nil, !hasMarkedText() else { return }
        if let imageAttachHandler, let image = ImageAttach.pastedImage(from: pasteboard) {
            imageAttachHandler([image])
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        pasteText(text)
    }

    /// テキストをペーストする。改行を `\r` にし、bracketed paste が有効なら囲む。
    /// 危険なテキストなら、利用者に確かめてから送る。live でなければ何もしない。
    public func pasteText(_ text: String) {
        guard let controller, !text.isEmpty else { return }
        Task { [weak self] in
            guard await controller.paste(text) == .needsConfirmation else { return }
            self?.confirmPaste(text) { confirmed in
                guard confirmed else { return }
                Task { _ = await controller.paste(text, allowUnsafe: true) }
            }
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(paste(_:)):
            // 選択が空でも Copy は有効にしておく（押しても何もしないだけ。Web 版と同じ）。
            return controller != nil && !hasMarkedText()
        default:
            return true
        }
    }

    /// 選択範囲が空でなければ pasteboard に書く。
    func copySelectionToPasteboard() {
        guard let controller else { return }
        Task { [weak self] in
            let text = await controller.selectionText()
            guard let self, !text.isEmpty else { return }
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
        }
    }

    private func confirmPaste(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        if let confirmUnsafePaste {
            confirmUnsafePaste(text, completion)
            return
        }
        guard let window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste text that may run commands?"
        alert.informativeText = "The text contains a line break or a bracketed-paste end sequence, "
            + "so the shell may run it as soon as it is pasted.\n\n" + Self.preview(of: text)
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response == .alertFirstButtonReturn) }
        }
    }

    /// 確認のシートに出す、ペーストするテキストの先頭（制御文字は見える形にする）。
    private static func preview(of text: String) -> String {
        let limit = 300
        var preview = String(text.prefix(limit))
            .replacingOccurrences(of: "\u{1b}", with: "␛")
        if text.count > limit {
            preview += "…"
        }
        return preview
    }

    /// 入力の状態（IME・マウス・フォーカス）を初期状態に戻す（端末を差し替えたとき）。
    func resetInputState() {
        discardMarkedText()
        resetPointerState()
    }
}
