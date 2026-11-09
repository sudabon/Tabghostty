import AppKit

/// 画像ファイルのドロップ（spec: image-attach「Image sources」、phase4 design D5）。
///
/// ファイルを運ぶドラッグが端末の上にある間は、点線の枠を出す（Web 版の `.terminal-drop-active` と同じ：
/// 2px の点線、accent 色、角丸 6、accent の 12% で塗る）。ドロップしたファイルのうち、添付できる画像
/// （PNG、JPEG、GIF、WebP）だけを `imageAttachHandler` に渡す。ほかのファイルは無視する。
extension TerminalView {
    func setUpImageDrop() {
        registerForDraggedTypes([.fileURL])
        dropFrame.isHidden = true
        dropFrame.color = dropHighlightColor
        dropFrame.autoresizingMask = [.width, .height]
        dropFrame.frame = bounds
        addSubview(dropFrame)
    }

    /// ドロップの枠を出しているか（テスト用）。
    public var isDropFrameVisible: Bool { !dropFrame.isHidden }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender.draggingPasteboard)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender.draggingPasteboard)
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropFrameVisible(false)
    }

    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        setDropFrameVisible(false)
    }

    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        ImageAttach.dragCarriesFiles(sender.draggingPasteboard) && imageAttachHandler != nil
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setDropFrameVisible(false)
        return dropFiles(from: sender.draggingPasteboard)
    }

    public override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        setDropFrameVisible(false)
    }

    /// ドロップされた pasteboard のファイルを添付する。添付できる画像が 1 つも無ければ false。
    @discardableResult
    public func dropFiles(from pasteboard: NSPasteboard) -> Bool {
        guard let imageAttachHandler, ImageAttach.dragCarriesFiles(pasteboard) else { return false }
        let images = ImageAttach.attachableImages(at: ImageAttach.droppedFileURLs(from: pasteboard))
        guard !images.isEmpty else { return false }
        imageAttachHandler(images)
        return true
    }

    /// ファイルを運んでいればコピーとして受け付け、枠を出す。そうでなければ受け付けない。
    func dragOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
        guard imageAttachHandler != nil, controller != nil, ImageAttach.dragCarriesFiles(pasteboard) else {
            setDropFrameVisible(false)
            return []
        }
        setDropFrameVisible(true)
        return .copy
    }

    private func setDropFrameVisible(_ visible: Bool) {
        guard dropFrame.isHidden == visible else { return }
        dropFrame.frame = bounds
        dropFrame.isHidden = !visible
    }
}

/// ドロップを受け付けている間の枠（マウスのイベントは受け取らない）。
@MainActor
final class DropFrameView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 2
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.12).setFill()
        path.fill()
        path.lineWidth = lineWidth
        path.setLineDash([6, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }
}
