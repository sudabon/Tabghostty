import AppKit
import DesktopSupport
import Testing
@testable import TabghosttyApp

/// 接続が切れている間の帯: 理由ごとの文言とボタン。
@MainActor
@Suite struct ConnectionLostBannerTests {
    // 切れている間のプローブの結果から、帯に出す理由を決める。応答を読み切れないもの（忙しいデーモンかもしれない）は再接続を待つ。
    @Test func reasonFollowsTheProbe() {
        #expect(ConnectionLostReason(probe: .daemon, port: 8642) == .reconnecting)
        #expect(ConnectionLostReason(probe: .unverified, port: 8642) == .reconnecting)
        #expect(ConnectionLostReason(probe: .notListening, port: 8642) == .daemonStopped)
        #expect(ConnectionLostReason(probe: .foreign, port: 8642) == .portInUse(port: 8642))
    }

    @Test func reconnectingShowsNoButton() {
        let banner = ConnectionLostBannerView()
        banner.show(.reconnecting) { Issue.record("the banner has no action while reconnecting") }
        #expect(banner.message.contains("Reconnecting"))
        #expect(banner.actionTitle == nil)
    }

    // 利用者が何かできるときはボタンを出す。押したら一度だけ動き、もう一度出すまでは押せない。
    @Test(arguments: [
        (ConnectionLostReason.daemonStopped, "Start Daemon", "not running"),
        (ConnectionLostReason.portInUse(port: 8642), "Retry", "port 8642"),
        (ConnectionLostReason.rejected(status: 401), "Reconnect", "HTTP 401"),
    ])
    func actionableReasonsShowAButtonThatRunsOnce(reason: ConnectionLostReason, title: String, text: String) {
        let banner = ConnectionLostBannerView()
        var runs = 0
        banner.show(reason) { runs += 1 }
        #expect(banner.message.contains(text))
        #expect(banner.actionTitle == title)
        banner.clickActionForTesting()
        banner.clickActionForTesting()
        #expect(runs == 1)

        banner.show(reason) { runs += 1 }
        banner.clickActionForTesting()
        #expect(runs == 2)
    }

    @Test func hideClearsTheMessage() {
        let banner = ConnectionLostBannerView()
        banner.show(.daemonStopped) {}
        banner.hide()
        #expect(banner.message.isEmpty)
        #expect(banner.actionTitle == nil)
    }

    // ウィンドウの中身を「接続中」「起動失敗」に替えたら、帯は消す。
    @Test func connectingAndStartupFailureHideTheBanner() {
        let controller = MainWindowController()
        controller.showConnectionLost(.daemonStopped) {}
        #expect(!controller.connectionLostBanner.message.isEmpty)
        controller.showConnecting()
        #expect(controller.connectionLostBanner.message.isEmpty)

        controller.showConnectionLost(.rejected(status: 401)) {}
        controller.showStartupFailure("failed") {}
        #expect(controller.connectionLostBanner.message.isEmpty)
    }
}
