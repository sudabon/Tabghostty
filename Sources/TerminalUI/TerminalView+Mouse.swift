import AppKit
import TerminalCore

/// ボタンを押してから離すまでの操作の種類。押したときに決め、離すまで変えない。
enum PointerGesture: Equatable {
    case none
    /// プログラムにマウスのイベントとして報告する。
    case report
    /// テキストを選択する。
    case select
}

/// マウス・スクロール・選択（spec: terminal-mouse / terminal-clipboard「Text selection」、phase2 design D3 / D5）。
///
/// - プログラムがマウスの報告を有効にしていて、Shift を押していなければ報告する（live のときだけ送る）。
/// - それ以外の左ボタンの操作は選択にする（ドラッグ・ダブルクリック・トリプルクリックはライブラリが解釈する）。
/// - スクロールは、報告 → alternate screen なら矢印キー → viewport の順で振り分ける（`TerminalController`）。
extension TerminalView {
    /// 選択をドラッグしてビューの上下の端を越えたときに、viewport を動かす間隔。
    static let autoscrollInterval: TimeInterval = 0.05

    // MARK: - ボタン

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Command+クリックでリンクを開く（spec: terminal-links）。リンクでなければ、ふつうのクリックとして扱う。
        if event.modifierFlags.contains(.command), pointerGesture == .none, handleCommandClick(event) {
            return
        }
        _ = pointerDown(event, button: .left)
    }

    public override func mouseDragged(with event: NSEvent) {
        pointerDragged(event, button: .left)
    }

    public override func mouseUp(with event: NSEvent) {
        pointerUp(event, button: .left)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if !pointerDown(event, button: .right) {
            super.rightMouseDown(with: event)
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        pointerDragged(event, button: .right)
    }

    public override func rightMouseUp(with event: NSEvent) {
        pointerUp(event, button: .right)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard let button = MouseInput.Button(buttonNumber: event.buttonNumber), pointerDown(event, button: button) else {
            super.otherMouseDown(with: event)
            return
        }
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard let button = MouseInput.Button(buttonNumber: event.buttonNumber) else { return }
        pointerDragged(event, button: button)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard let button = MouseInput.Button(buttonNumber: event.buttonNumber) else { return }
        pointerUp(event, button: button)
    }

    public override func mouseMoved(with event: NSEvent) {
        updateLinkHover(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
        // ボタンを押さない移動は、any-event tracking（DECSET 1003）のときだけ報告する。
        guard let controller, pointerGesture == .none, controller.inputModes.mouseTracking == .any,
              !event.modifierFlags.contains(.shift) else { return }
        controller.enqueueMouse(mouseInput(.motion, button: nil, event: event))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    public override func mouseExited(with event: NSEvent) {
        updateLinkHover(at: nil, modifiers: [])
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
        // Command を押してリンクの上にいる間は、リンクのセルを指の形にする。
        for span in hoveredLink?.spans ?? [] {
            addCursorRect(cellRect(x: span.columns.lowerBound, y: span.row, width: span.columns.count), cursor: .pointingHand)
        }
    }

    /// ボタンを押した。
    /// - Returns: 報告または選択として扱ったら true
    func pointerDown(_ event: NSEvent, button: MouseInput.Button) -> Bool {
        guard let controller else { return false }
        if pointerGesture == .report || shouldReportMouse(event, controller: controller) {
            // 報告は live のときだけ送る（コントローラが判定する）。replay 中は選択にもしない。
            pointerGesture = .report
            pressedButtons.insert(button)
            controller.enqueueMouse(mouseInput(.press, button: button, event: event))
            return true
        }
        guard button == .left else { return false }
        pointerGesture = .select
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        let timestamp = UInt64(max(0, event.timestamp) * 1_000_000_000)
        let interval = UInt64(NSEvent.doubleClickInterval * 1_000_000_000)
        let distance = Double(max(metrics.widthPx, metrics.heightPx))
        controller.enqueueSelection(selectionInput(
            .press(timeNanoseconds: timestamp, repeatIntervalNanoseconds: interval, repeatDistance: distance),
            at: point
        ))
        return true
    }

    func pointerDragged(_ event: NSEvent, button: MouseInput.Button) {
        guard let controller else { return }
        switch pointerGesture {
        case .report:
            // ドラッグは button-event tracking（DECSET 1002）以上のときだけ、エンコーダが出力する。
            controller.enqueueMouse(mouseInput(.motion, button: button, event: event))
        case .select:
            guard button == .left else { return }
            let point = convert(event.locationInWindow, from: nil)
            lastDragPoint = point
            controller.enqueueSelection(selectionInput(.drag, at: point))
            updateAutoscroll(point)
        case .none:
            break
        }
    }

    func pointerUp(_ event: NSEvent, button: MouseInput.Button) {
        guard let controller else {
            resetPointerState()
            return
        }
        switch pointerGesture {
        case .report:
            guard pressedButtons.remove(button) != nil else { return }
            controller.enqueueMouse(mouseInput(.release, button: button, event: event))
            if pressedButtons.isEmpty {
                pointerGesture = .none
            }
        case .select:
            guard button == .left else { return }
            let point = convert(event.locationInWindow, from: nil)
            controller.enqueueSelection(selectionInput(.release, at: point))
            stopAutoscroll()
            pointerGesture = .none
            if inputSettings.copyOnSelect {
                // 選択を終えたら、空でなければコピーする（spec: terminal-clipboard「Copy on select」）。
                copySelectionToPasteboard()
            }
        case .none:
            break
        }
    }

    /// プログラムに報告するか。マウスの報告が有効で、Shift を押していないとき。
    private func shouldReportMouse(_ event: NSEvent, controller: TerminalController) -> Bool {
        controller.inputModes.mouseTracking != .none && !event.modifierFlags.contains(.shift)
    }

    // MARK: - スクロール（design D5）

    public override func scrollWheel(with event: NSEvent) {
        guard let controller else { return }
        if event.phase == .began || event.phase == .mayBegin {
            scrollAccumulator.reset()
        }
        let lines = scrollAccumulator.add(
            Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            cellHeight: Double(metrics.height)
        )
        guard lines != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let position = GridGeometry.surfacePosition(point, scale: metrics.scale)
        controller.enqueueScroll(ScrollInput(
            lines: lines,
            x: position.x,
            y: position.y,
            modifiers: KeyInput.Modifiers(event.modifierFlags),
            surface: mouseSurface
        ))
    }

    // MARK: - 選択の自動スクロール

    /// ドラッグがビューの上下の端を越えている間、タイマーで viewport を動かして選択を伸ばす。
    /// 1 回に動かす行数は、端を越えた距離で決める（`GridGeometry.autoscrollRows`）。
    private func updateAutoscroll(_ point: CGPoint) {
        guard GridGeometry.autoscrollRows(pointY: point.y, viewHeight: bounds.height) > 0 else {
            stopAutoscroll()
            return
        }
        guard autoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.autoscrollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    func autoscrollTick() {
        guard pointerGesture == .select, let controller else {
            stopAutoscroll()
            return
        }
        // ライブラリの 1 回の tick は viewport を 1 行動かすので、動かす行数の分だけ送る。
        let rows = GridGeometry.autoscrollRows(pointY: lastDragPoint.y, viewHeight: bounds.height)
        for _ in 0..<rows {
            controller.enqueueSelection(selectionInput(.autoscrollTick, at: lastDragPoint))
        }
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// マウスの状態を初期状態に戻す（端末を差し替えたときなど）。
    func resetPointerState() {
        stopAutoscroll()
        pointerGesture = .none
        pressedButtons.removeAll()
        scrollAccumulator.reset()
    }

    // MARK: - 座標

    /// 描画領域の大きさ（device pixel）。
    var mouseSurface: MouseSurface {
        GridGeometry.mouseSurface(viewSize: bounds.size, cell: metrics, cols: gridColumns, rows: gridRows)
    }

    private func mouseInput(_ action: MouseInput.Action, button: MouseInput.Button?, event: NSEvent) -> MouseInput {
        let point = convert(event.locationInWindow, from: nil)
        let position = GridGeometry.surfacePosition(point, scale: metrics.scale)
        return MouseInput(
            action: action,
            button: button,
            modifiers: KeyInput.Modifiers(event.modifierFlags),
            x: position.x,
            y: position.y,
            anyButtonPressed: !pressedButtons.isEmpty,
            surface: mouseSurface
        )
    }

    private func selectionInput(_ kind: SelectionInput.Kind, at point: CGPoint) -> SelectionInput {
        let position = GridGeometry.surfacePosition(point, scale: metrics.scale)
        return SelectionInput(
            kind: kind,
            cell: GridGeometry.cell(at: point, cell: metrics, cols: gridColumns, rows: gridRows),
            x: position.x,
            y: position.y,
            surface: mouseSurface
        )
    }
}
