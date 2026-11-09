import AppKit
import TerminalCore

/// 検索バーの操作（Edit メニューから first responder に送られる）。
@MainActor
@objc public protocol TerminalFindActions {
    /// Command-F: 検索バーを開き、検索欄にフォーカスを移す。
    func showFindBar(_ sender: Any?)
    /// Command-G: 次の一致へ。
    func findNext(_ sender: Any?)
    /// Command-Shift-G: 前の一致へ。
    func findPrevious(_ sender: Any?)
}

/// 端末の中の検索（spec: terminal-search、phase5 design D5）。
///
/// - 検索バーは端末の右上に重ねる。対象はアクティブなセッションの画面とスクロールバック。
/// - 入力のたびに検索し、最初の一致まで viewport を動かす。新しい出力が来たら、端末が 200 ms 後に検索し直す。
/// - 一致はすべて強調し、今の一致は別の色にする（`rowCellColors`）。
/// - 閉じると強調を消し、キーボードフォーカスを端末に戻す。
extension TerminalView: TerminalFindActions {
    /// 検索バーを出しているか。
    public var isFindBarVisible: Bool { findBar.superview != nil && !findBar.isHidden }

    /// 検索バー（テスト用）。
    var findBarForTesting: FindBarView { findBar }

    @objc public func showFindBar(_ sender: Any?) {
        installFindBarIfNeeded()
        findBar.isHidden = false
        findBar.focusField()
        if !findBar.query.isEmpty {
            runSearch(findBar.query)
        }
    }

    @objc public func findNext(_ sender: Any?) {
        guard isFindBarVisible, !findBar.query.isEmpty else {
            showFindBar(sender)
            return
        }
        navigateSearch(forward: true)
    }

    @objc public func findPrevious(_ sender: Any?) {
        guard isFindBarVisible, !findBar.query.isEmpty else {
            showFindBar(sender)
            return
        }
        navigateSearch(forward: false)
    }

    /// 検索バーを閉じ、強調を消して、端末にフォーカスを戻す。
    public func closeFindBar() {
        guard isFindBarVisible else { return }
        let hadFocus = findBar.hasFocus
        findBar.isHidden = true
        searchSequence += 1
        if let controller {
            Task { await controller.endSearch() }
        }
        if hadFocus || window?.firstResponder == nil {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - 内部

    private func installFindBarIfNeeded() {
        guard findBar.superview == nil else { return }
        findBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(findBar, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        findBar.onQueryChange = { [weak self] query in self?.runSearch(query) }
        findBar.onNext = { [weak self] in self?.navigateSearch(forward: true) }
        findBar.onPrevious = { [weak self] in self?.navigateSearch(forward: false) }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
    }

    /// 検索し、件数を出す。遅れて返ってきた古い結果は使わない。
    func runSearch(_ query: String) {
        guard let controller else {
            findBar.status = .empty
            return
        }
        searchSequence += 1
        let sequence = searchSequence
        Task { [weak self] in
            let status = await controller.search(query)
            guard let self, sequence == self.searchSequence, self.controller === controller else { return }
            self.findBar.status = status
        }
    }

    private func navigateSearch(forward: Bool) {
        guard let controller else { return }
        searchSequence += 1
        let sequence = searchSequence
        Task { [weak self] in
            let status = forward ? await controller.searchNext() : await controller.searchPrevious()
            guard let self, sequence == self.searchSequence, self.controller === controller else { return }
            self.findBar.status = status
        }
    }

    /// 表示するセッションが変わった。検索バーを開いていれば、新しいセッションを同じ文字列で検索する。
    func searchSessionDidChange(from old: TerminalController?) {
        old?.setSearchObserver(nil)
        if let old, isFindBarVisible {
            Task { await old.endSearch() }
        }
        controller?.setSearchObserver { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 新しい出力のあとに検索し直した結果。今の文字列のものだけを出す。
                    guard let self, self.isFindBarVisible, status.query == self.findBar.query else { return }
                    self.findBar.status = status
                }
            }
        }
        guard isFindBarVisible else { return }
        runSearch(findBar.query)
    }

    /// 行 `y` の列 `x` の検索の強調（今の一致なら `.current`）。
    func searchHighlightKind(x: Int, y: Int) -> SearchHighlightKind? {
        guard let spans = searchHighlights[y] else { return nil }
        var kind: SearchHighlightKind?
        for span in spans where span.columns.contains(x) {
            if span.isCurrent { return .current }
            kind = .match
        }
        return kind
    }

    enum SearchHighlightKind {
        case match, current
    }
}
