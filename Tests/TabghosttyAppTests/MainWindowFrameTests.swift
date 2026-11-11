import AppKit
import Testing
@testable import TabghosttyApp

/// spec: app-shell「Main window」: ウィンドウの位置と大きさを、次の起動で戻す。
///
/// 自動保存名は、テストごとに一意のものを使う（design D2）。同じ名前のウィンドウが同時にあると名前の設定に失敗し、
/// アプリ本体の名前で書くと、テストを実行するプロセスのユーザーデフォルトに、本体と同じキーが残るため。
@MainActor
@Suite struct MainWindowFrameTests {
    private static func uniqueName() -> String {
        "TabghosttyTest-\(UUID().uuidString)"
    }

    /// 保存した枠を読み書きするためだけの、画面に出さないウィンドウ。
    private static func makeProbeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// 画面に収まる枠（画面が変わったときの補正が入らないように、見える範囲の内側にとる）。
    private static func frameOnMainScreen(offset: CGFloat, size: NSSize) throws -> NSRect {
        let visible = try #require(NSScreen.main).visibleFrame
        return NSRect(origin: NSPoint(x: visible.minX + offset, y: visible.minY + offset), size: size)
    }

    // ウィンドウコントローラを作った後も、自動保存名が残っている（コントローラが空の名前で上書きしていた不具合）。
    @Test func autosaveNameSurvivesTheWindowController() throws {
        let name = Self.uniqueName()
        defer { NSWindow.removeFrame(usingName: name) }

        let controller = MainWindowController(frameAutosaveName: name)
        let window = try #require(controller.window)
        #expect(window.frameAutosaveName == name)
    }

    // 保存された枠があれば、その位置と大きさで開く。
    @Test(.enabled("画面がある環境だけ") { await MainActor.run { NSScreen.main != nil } })
    func opensWithTheSavedFrame() throws {
        let name = Self.uniqueName()
        defer { NSWindow.removeFrame(usingName: name) }
        let saved = try Self.frameOnMainScreen(offset: 40, size: NSSize(width: 640, height: 400))
        let probe = Self.makeProbeWindow()
        probe.setFrame(saved, display: false)
        probe.saveFrame(usingName: name)

        let controller = MainWindowController(frameAutosaveName: name)
        let window = try #require(controller.window)
        #expect(window.frame == saved)
    }

    // 位置や大きさを変えると、そのたびに保存される（終了の経路によらず、次の起動で戻る）。
    @Test(.enabled("画面がある環境だけ") { await MainActor.run { NSScreen.main != nil } })
    func savesTheFrameWhenItChanges() throws {
        let name = Self.uniqueName()
        defer { NSWindow.removeFrame(usingName: name) }
        let controller = MainWindowController(frameAutosaveName: name)
        let window = try #require(controller.window)

        let moved = try Self.frameOnMainScreen(offset: 60, size: NSSize(width: 700, height: 450))
        window.setFrame(moved, display: false)

        let probe = Self.makeProbeWindow()
        #expect(probe.setFrameUsingName(name))
        #expect(probe.frame == moved)
    }

    // 保存された枠が無ければ、初めの大きさ（内容が 1100×720）で開く。
    @Test func opensAtTheInitialSizeWithoutASavedFrame() throws {
        let name = Self.uniqueName()
        defer { NSWindow.removeFrame(usingName: name) }

        let controller = MainWindowController(frameAutosaveName: name)
        let window = try #require(controller.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == MainWindowController.initialSize)
    }
}
