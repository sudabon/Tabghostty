import AppKit
import TerminalCore

/// リンク（spec: terminal-links「Opening links」、phase5 design D6）。
///
/// - Command を押している間だけ、ポインタの下のリンクを探す（OSC 8 を端末に問い合わせ、無ければ表示している
///   セルから素の URL を探す）。見つかったらセルに下線を引き、ポインタを指の形にする。
/// - Command+クリックで、`http` / `https` のリンクを既定のアプリで開く。ほかのスキームは開かない。
/// - 修飾キー無しのクリックは、これまでどおり選択やマウスの報告になる（リンクは開かない）。
extension TerminalView {
    /// ポインタが動いた・修飾キーが変わった。Command を押していればリンクを探し、離していれば下線を消す。
    func updateLinkHover(at location: CGPoint?, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.contains(.command), let location, bounds.contains(location), controller != nil else {
            linkLookupSequence += 1
            setHoveredLink(nil)
            return
        }
        let cell = GridGeometry.cell(at: location, cell: metrics, cols: gridColumns, rows: gridRows)
        lastLinkCell = cell
        if let hoveredLink, hoveredLink.contains(cell) { return }
        lookUpLink(at: cell) { [weak self] link in
            guard let self, self.commandKeyIsDown() else { return }
            self.setHoveredLink(link)
        }
    }

    /// Command+クリック。リンクの上なら開いて（開いてよいスキームのときだけ）true を返す。
    /// リンクでなければ false を返し、ふつうのクリック（選択・マウスの報告）として扱う。
    func handleCommandClick(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let cell = GridGeometry.cell(at: point, cell: metrics, cols: gridColumns, rows: gridRows)
        if let hoveredLink, hoveredLink.contains(cell) {
            open(hoveredLink)
            return true
        }
        if let plain = LinkDetector.plainLink(at: cell, rows: cells, wrapped: rowWrapped) {
            open(plain)
            return true
        }
        // OSC 8 は端末に問い合わせる（ふつうは、Command を押した時点でホバーの検索が済んでいる）。
        lookUpLink(at: cell) { [weak self] link in
            guard let link, link.kind == .hyperlink else { return }
            self?.open(link)
        }
        return false
    }

    /// 開いてよいリンク（`http` / `https`）だけを開く（spec: terminal-links「Unsafe scheme」）。
    private func open(_ link: TerminalLink) {
        guard link.isOpenable, let url = URL(string: link.url) else { return }
        linkOpener(url)
    }

    /// セルのリンクを探す。OSC 8 を先に見て、無ければ表示しているセルから素の URL を探す。
    /// 遅れて返ってきた古い結果は使わない。
    private func lookUpLink(at cell: GridPoint, completion: @escaping (TerminalLink?) -> Void) {
        guard let controller else {
            completion(nil)
            return
        }
        linkLookupSequence += 1
        let sequence = linkLookupSequence
        Task { [weak self] in
            let hyperlink = await controller.hyperlink(at: cell)
            guard let self, sequence == self.linkLookupSequence, self.controller === controller else { return }
            completion(hyperlink ?? LinkDetector.plainLink(at: cell, rows: self.cells, wrapped: self.rowWrapped))
        }
    }

    /// 下線を引くリンクを変え、そのリンクの行を描き直し、ポインタの形を変える。
    func setHoveredLink(_ link: TerminalLink?) {
        guard link != hoveredLink else { return }
        for span in (hoveredLink?.spans ?? []) + (link?.spans ?? []) where span.row >= 0 && span.row < gridRows {
            renderer.invalidate(rowRect(span.row))
        }
        hoveredLink = link
        window?.invalidateCursorRects(for: self)
        if link != nil {
            NSCursor.pointingHand.set()
        } else if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.iBeam.set()
        }
    }

    /// 端末の内容が変わって、下線を引いているリンクの行が書き換わった。下線を消し、Command を押したままなら探し直す。
    func linkRowsChanged(_ rows: IndexSet, all: Bool) {
        guard let hoveredLink, all || hoveredLink.spans.contains(where: { rows.contains($0.row) }) else { return }
        setHoveredLink(nil)
        if let lastLinkCell, commandKeyIsDown() {
            lookUpLink(at: lastLinkCell) { [weak self] link in self?.setHoveredLink(link) }
        }
    }

    /// 下線を引いているリンクのセルの線（Core Text と Metal で同じ線を描く）。
    func hoveredLinkUnderlines() -> [DecorationGeometry.Line] {
        guard let hoveredLink else { return [] }
        let geometry = DecorationGeometry(metrics: metrics, font: fonts.regular)
        var lines: [DecorationGeometry.Line] = []
        for span in hoveredLink.spans where span.row >= 0 && span.row < rows {
            let row = cells[span.row]
            let rowTop = GridGeometry.padding + CGFloat(span.row) * metrics.height
            let top = geometry.underlineTop(rowTop: rowTop)
            for x in span.columns where x >= 0 && x < row.count {
                let cell = row[x]
                guard cell.width != .spacerTail else { continue }
                let width = CGFloat(cell.width == .wide ? 2 : 1) * metrics.width
                lines.append(DecorationGeometry.Line(
                    rect: CGRect(x: GridGeometry.padding + CGFloat(x) * metrics.width, y: top, width: width, height: geometry.thickness),
                    style: .solid,
                    color: rowCellColors(cell, x: x, y: span.row).foreground,
                    alpha: 1
                ))
            }
        }
        return lines
    }
}
