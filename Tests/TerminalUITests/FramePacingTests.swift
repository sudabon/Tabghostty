import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// phase5 design D3 / spec: terminal-rendering「Idle efficiency」。
@MainActor
@Suite struct FramePacingTests {
    private let start = ContinuousClock.now

    @Test func pausesAfterASecondWithoutChanges() {
        var pacer = FramePacer(now: start)
        let r1 = pacer.tick(at: start + .milliseconds(16), busy: false)
        #expect(!r1)
        let r2 = pacer.tick(at: start + .milliseconds(990), busy: false)
        #expect(!r2)
        let r3 = pacer.tick(at: start + .milliseconds(1001), busy: false)
        #expect(r3)
        #expect(pacer.isPaused)
        // 止めている間の tick は何もしない。
        let r4 = pacer.tick(at: start + .seconds(2), busy: false)
        #expect(!r4)
    }

    @Test func busyFramesKeepItRunning() {
        var pacer = FramePacer(now: start)
        let r5 = pacer.tick(at: start + .milliseconds(900), busy: true)
        #expect(!r5)
        // 最後に描くものがあった tick から 1 秒。
        let r6 = pacer.tick(at: start + .milliseconds(1800), busy: false)
        #expect(!r6)
        let r7 = pacer.tick(at: start + .milliseconds(1901), busy: false)
        #expect(r7)
    }

    @Test func activityResumesAPausedLink() {
        var pacer = FramePacer(now: start)
        let r8 = pacer.tick(at: start + .seconds(2), busy: false)
        #expect(r8)
        let r9 = pacer.activity(at: start + .seconds(3))
        #expect(r9)
        #expect(!pacer.isPaused)
        // 動いているときの activity は、止めるまでの時間を延ばすだけ。
        let r10 = pacer.activity(at: start + .milliseconds(3500))
        #expect(!r10)
        let r11 = pacer.tick(at: start + .milliseconds(4400), busy: false)
        #expect(!r11)
        let r12 = pacer.tick(at: start + .milliseconds(4501), busy: false)
        #expect(r12)
    }

    // カーソルの点滅は、描くために再開するが、止めるまでの時計は戻さない（点滅が続いても、合間は止まる）。
    @Test func blinkWakesForAFrameWithoutKeepingTheLinkRunning() {
        var pacer = FramePacer(now: start)
        let paused = pacer.tick(at: start + .seconds(2), busy: false)
        #expect(paused)
        // 点滅で再開する。
        let resumed = pacer.activity(at: start + .milliseconds(2530), countsAsActivity: false)
        #expect(resumed)
        #expect(!pacer.isPaused)
        // 点滅のフレームを描いたら、描くものが無いので、すぐに止める。
        let pausedAgain = pacer.tick(at: start + .milliseconds(2546), busy: false)
        #expect(pausedAgain)
        // 動いている間の点滅は、止めるまでの時間を延ばさない。
        let r1 = pacer.activity(at: start + .seconds(3))
        #expect(r1)
        let r2 = pacer.activity(at: start + .milliseconds(3530), countsAsActivity: false)
        #expect(!r2)
        let r3 = pacer.tick(at: start + .milliseconds(4001), busy: false)
        #expect(r3)
    }

    // Scenario: Hidden window — 見えていない間は、変化があっても止めたまま（点滅のフレームも描かない）。
    @Test func hiddenWindowStaysPausedUntilVisible() {
        var pacer = FramePacer(now: start)
        let r13 = pacer.setVisible(false, at: start)
        #expect(!r13)
        #expect(pacer.isPaused)
        let r14 = pacer.activity(at: start + .seconds(1))
        #expect(!r14)
        #expect(pacer.isPaused)
        let r15 = pacer.setVisible(true, at: start + .seconds(2))
        #expect(r15)
        #expect(!pacer.isPaused)
    }

    @Test func hiddenViewStopsTheCursorBlink() throws {
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: .coreText)
        view.setWindowVisible(false)
        #expect(!view.pacer.isVisible)
        #expect(view.isDisplayLinkPaused)
        view.wakeDisplayLink()
        #expect(view.isDisplayLinkPaused)
        view.setWindowVisible(true)
        #expect(view.pacer.isVisible)
    }

    // 端末に変化が起きたら（無い状態から、ある状態になったら）、表示しているビューに知らせる。
    @Test func controllerNotifiesOnlyWhenRenderBecomesPending() async throws {
        let controller = try TerminalController(sid: "s1", cols: 20, rows: 4, maxScrollback: 10, colors: nil, sink: RecordingSink())
        await controller.attach()
        await controller.receiveReplay(Array("hi".utf8), done: true)
        _ = await controller.makeSnapshot(forceFull: true)
        let count = Counter()
        controller.setRenderObserver { count.increment() }
        await controller.receiveOutput(Array("a".utf8))
        await controller.receiveOutput(Array("b".utf8))
        // まだスナップショットを取っていないので、2 回目は知らせない。
        #expect(count.value == 1)
        _ = await controller.makeSnapshot()
        await controller.receiveOutput(Array("c".utf8))
        #expect(count.value == 2)
        controller.setRenderObserver(nil)
        _ = await controller.makeSnapshot()
        await controller.receiveOutput(Array("d".utf8))
        #expect(count.value == 2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
