import AppKit
import DaemonClient

/// タブメモの文字数（spec: tab-operations「Edit a tab memo」）。上限は Unicode の code point で数える
/// （webtabinal `util.ts` の `unicodeLength` / `clampUnicode`。デーモンも rune で検証する）。
public enum MemoText {
    public static let maxCodePoints = 30

    /// code point の数（UTF-16 の長さではない）。
    public static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// 先頭から `max` code point までに収める。
    public static func clamp(_ text: String, max: Int = maxCodePoints) -> String {
        guard text.unicodeScalars.count > max else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(max)))
    }

    /// 残りの文字数（「残り N」）。
    public static func remaining(_ text: String) -> Int {
        Swift.max(0, maxCodePoints - length(text))
    }

    /// 保存する値（前後の空白を削る。空ならメモを消す）。
    public static func normalizedForSave(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 最後のタブを閉じたときにすること（spec: tab-operations「Behavior when the last tab closes」）。
public enum LastTabOutcome: Equatable, Sendable {
    case none
    /// アプリを終了する（デーモンは残す）。
    case quit
    /// 「すべてのタブを閉じました」を出す。
    case showEmptyState
}

public enum TabPolicy {
    /// セッションの数が 1 件以上から 0 件になったら、`quit_when_no_tabs` に従って決める。
    /// - Parameter previousCount: 前の数（最初の一覧を受け取る前は nil）
    public static func lastTabOutcome(previousCount: Int?, currentCount: Int, quitWhenNoTabs: Bool) -> LastTabOutcome {
        guard let previousCount, previousCount > 0, currentCount == 0 else { return .none }
        return quitWhenNoTabs ? .quit : .showEmptyState
    }

    /// 閉じる前に確かめるか（`confirm_close_running` が有効で、実行中）。
    public static func needsCloseConfirmation(_ session: SessionInfo, confirmCloseRunning: Bool) -> Bool {
        confirmCloseRunning && session.state == "running"
    }

    /// 閉じるときの確認の文言。
    public static let closeConfirmationMessage = "このタブは実行中です。閉じますか？"
}

/// 右クリックメニューの項目（spec: tab-operations「Tab context menu」）。
public struct TabMenuItemState: Equatable, Sendable {
    public enum Action: Sendable {
        case duplicate
        case restart
        case close
        case toggleNotifications
    }

    public var action: Action
    public var title: String
    public var isEnabled: Bool
    /// チェックの付く項目なら、その状態。
    public var isChecked: Bool?
}

public enum TabContextMenu {
    /// 項目と、押せるかどうか（webtabinal `TabContextMenu.tsx` と同じ 4 項目）。
    public static func items(for session: SessionInfo) -> [TabMenuItemState] {
        [
            TabMenuItemState(action: .duplicate, title: "複製", isEnabled: true, isChecked: nil),
            TabMenuItemState(action: .restart, title: "再起動", isEnabled: session.isExited, isChecked: nil),
            TabMenuItemState(action: .close, title: "閉じる", isEnabled: true, isChecked: nil),
            TabMenuItemState(action: .toggleNotifications, title: "通知", isEnabled: true, isChecked: !session.notificationsMuted),
        ]
    }

    /// `NSMenu` を作る。項目を選ぶと `perform` に操作を渡す。
    @MainActor
    public static func makeMenu(for session: SessionInfo, perform: @escaping (TabMenuItemState.Action) -> Void) -> NSMenu {
        let menu = NSMenu(title: "タブの操作")
        menu.autoenablesItems = false
        let target = MenuActionTarget(perform: perform)
        for state in items(for: session) {
            let item = NSMenuItem(title: state.title, action: #selector(MenuActionTarget.choose(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = MenuActionBox(state.action)
            item.isEnabled = state.isEnabled
            if let checked = state.isChecked {
                item.state = checked ? .on : .off
            }
            menu.addItem(item)
        }
        // メニューが閉じるまで target を持たせておく。
        objc_setAssociatedObject(menu, &MenuActionTarget.associationKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }
}

private final class MenuActionBox: NSObject {
    let action: TabMenuItemState.Action
    init(_ action: TabMenuItemState.Action) { self.action = action }
}

@MainActor
private final class MenuActionTarget: NSObject {
    nonisolated(unsafe) static var associationKey: UInt8 = 0
    let perform: (TabMenuItemState.Action) -> Void

    init(perform: @escaping (TabMenuItemState.Action) -> Void) {
        self.perform = perform
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuActionBox else { return }
        perform(box.action)
    }
}
