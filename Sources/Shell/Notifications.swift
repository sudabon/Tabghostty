import DaemonClient
import DesktopSupport
import Foundation
import os

/// 通知の内容。
public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// 通知を出すか、タブを未読にするかの判定（webtabinal `web/src/notify.ts` と `App.tsx` L213-275 の移植。
/// spec: notifications「Notification decision」「Notification content」、phase4 design D1）。
///
/// 順序は Web 版と同じ。
/// 1. `notification.enabled` が false なら何もしない。
/// 2. アクティブなタブで、ウィンドウにフォーカスがあり、`always` が false なら何もしない。
/// 3. 完了イベントだけ、`min_duration_ms` が 0 より大きく `run_ms` がそれ未満なら何もしない。
/// 4. アクティブなタブでなければ未読にする。
/// 5. ミュートしていれば通知を出さない。
/// 6. `commands` が空でなく、コマンド名が一覧に無ければ通知を出さない。
/// 7. それ以外は通知を出す。
///
/// `kind` と `source` は判定に使わない（重複の排除はデーモンの責務）。
public enum NotificationDecision {
    public struct Result: Equatable, Sendable {
        /// タブを未読にするか。
        public var markUnread: Bool
        /// 出す通知（出さないなら nil）。
        public var content: NotificationContent?

        public static let none = Result(markUnread: false, content: nil)

        public init(markUnread: Bool, content: NotificationContent?) {
            self.markUnread = markUnread
            self.content = content
        }
    }

    /// 判定する。
    /// - Parameters:
    ///   - session: イベントが起きたセッション（完了イベントなら反映した後のもの）。一覧に無ければ nil
    ///   - isActive: アクティブなタブか
    ///   - windowFocused: メインウィンドウにフォーカスがあるか
    public static func evaluate(
        event: SessionEvent,
        session: SessionInfo?,
        isActive: Bool,
        windowFocused: Bool,
        config: NotificationSettings
    ) -> Result {
        let content: NotificationContent
        var minDurationMs: Int64?
        var runMs: Int64?
        switch event {
        case .commandFinished(let finished):
            content = completionContent(finished)
            minDurationMs = config.minDurationMs
            runMs = finished.runMs
        case .agentWaiting(_, let title, let body):
            guard let wait = agentWaitContent(title: title, body: body, command: session?.command) else { return .none }
            content = wait
        }
        guard shouldRaise(
            enabled: config.enabled,
            always: config.always,
            active: isActive,
            focused: windowFocused,
            minDurationMs: minDurationMs,
            runMs: runMs
        ) else { return .none }
        let markUnread = !isActive
        guard sessionAllowsNotification(session), commandAllowsNotification(session?.command, config.commands) else {
            return Result(markUnread: markUnread, content: nil)
        }
        return Result(markUnread: markUnread, content: content)
    }

    /// 手順 1〜3（`shouldRaiseDesktopNotification`）。待ちイベントでは `minDurationMs` を渡さない。
    public static func shouldRaise(
        enabled: Bool,
        always: Bool,
        active: Bool,
        focused: Bool,
        minDurationMs: Int64? = nil,
        runMs: Int64? = nil
    ) -> Bool {
        guard enabled else { return false }
        if !always && active && focused { return false }
        let minimum = minDurationMs ?? 0
        if minimum > 0 && (runMs ?? 0) < minimum { return false }
        return true
    }

    /// 手順 5（`sessionAllowsNotification`）。ミュートしたタブは、未読は付くがバナーを出さない。
    public static func sessionAllowsNotification(_ session: SessionInfo?) -> Bool {
        !(session?.notificationsMuted ?? false)
    }

    /// 手順 6（`commandAllowsNotification`）。
    ///
    /// コマンドの先頭の語の basename で比べる（`make build` は `make`、`/usr/local/bin/claude --resume` は `claude`）。
    /// 一覧が空なら絞り込まない。一覧があるとき、コマンドが分からないセッションは一致しない。
    /// 大文字小文字は区別しない（macOS のテキストフィールドは先頭を大文字にすることがあるため）。
    public static func commandAllowsNotification(_ command: String?, _ commands: [String]) -> Bool {
        let allowed = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !allowed.isEmpty else { return true }
        let first = (command ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first.map(String.init) ?? ""
        let name = (first.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "").lowercased()
        guard !name.isEmpty else { return false }
        return allowed.contains(name)
    }

    /// 待ちイベントの内容（`agentWaitContent`）。title と body が両方空なら nil。
    /// title が空なら、セッションのコマンド、`Tabghostty` の順に使う。
    public static func agentWaitContent(title: String, body: String, command: String?) -> NotificationContent? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else { return nil }
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = trimmedCommand.isEmpty ? "Tabghostty" : trimmedCommand
        return NotificationContent(title: trimmedTitle.isEmpty ? fallback : trimmedTitle, body: trimmedBody)
    }

    /// 完了イベントの内容。title は `✓ <command>`（exit が 0 か不明）か `✗ <command> (exit N)`、
    /// body は `<ディレクトリ> ・ <秒>s`（`run_ms` を 1000 で割って四捨五入）。
    public static func completionContent(_ session: SessionInfo) -> NotificationContent {
        let ok = session.exit == nil || session.exit == 0
        let title = ok ? "✓ \(session.command)" : "✗ \(session.command) (exit \(session.exit ?? 0))"
        let seconds = (Double(session.runMs ?? 0) / 1000).rounded(.toNearestOrAwayFromZero)
        let body = "\(cwdBasename(session.cwd)) ・ \(Int(seconds))s"
        return NotificationContent(title: title, body: body)
    }
}

/// イベント → 判定 → 未読 → 通知（phase4 design D1）。
///
/// 通知の設定は、イベントのたびに `ConfigStore` から読む（ブラウザ版で変えた設定も、読み直した後なら効く）。
/// 通知の許可が無くても、未読と Dock バッジは付く（spec: notifications「User-initiated authorization」）。
@MainActor
public final class NotificationCoordinator {
    private let store: SessionStore
    private let settings: () -> NotificationSettings
    private let unread: UnreadTracker
    private let service: (any NativeNotificationServicing)?
    /// メインウィンドウにフォーカスがあるか。
    public var isWindowFocused: () -> Bool = { false }
    private static let log = Logger(subsystem: "com.tabghostty.app", category: "notifications")

    public init(
        store: SessionStore,
        settings: @escaping () -> NotificationSettings,
        unread: UnreadTracker,
        service: (any NativeNotificationServicing)?
    ) {
        self.store = store
        self.settings = settings
        self.unread = unread
        self.service = service
    }

    /// イベントを判定し、未読にして、通知を出す。判定の結果を返す。
    @discardableResult
    public func handle(_ event: SessionEvent) -> NotificationDecision.Result {
        let session: SessionInfo?
        if case .commandFinished(let finished) = event {
            session = finished
        } else {
            session = store.sessions.first { $0.id == event.sid }
        }
        let decision = NotificationDecision.evaluate(
            event: event,
            session: session,
            isActive: store.activeSessionID == event.sid,
            windowFocused: isWindowFocused(),
            config: settings()
        )
        if decision.markUnread {
            unread.markUnread(event.sid)
        }
        if let content = decision.content, let service {
            let sid = event.sid
            Task {
                do {
                    try await service.show(sessionID: sid, title: content.title, body: content.body)
                } catch {
                    Self.log.info("Notification was not delivered: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return decision
    }
}
