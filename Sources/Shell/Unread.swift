import AppKit
import DaemonClient

/// 未読のタブ（`UnreadTracker`。spec: tab-sidebar「Unread dots and Dock badge」）。選択したら消え、一覧から消えたセッションは数えない。
@MainActor
public final class UnreadTracker {
    public private(set) var unreadIDs: Set<String> = []
    /// 未読の集合が変わった。
    public var onChange: (() -> Void)?

    public init() {}

    public var count: Int { unreadIDs.count }

    public func contains(_ id: String) -> Bool {
        unreadIDs.contains(id)
    }

    /// タブを未読にする（未読にするかの判定は `NotificationDecision`）。
    public func markUnread(_ id: String) {
        guard unreadIDs.insert(id).inserted else { return }
        onChange?()
    }

    /// 選択したタブの未読を消す。
    public func markRead(_ id: String) {
        guard unreadIDs.remove(id) != nil else { return }
        onChange?()
    }

    /// 一覧に無いセッションを未読から取り除く（Web 版では閉じたタブが数に残る不具合を直す）。
    public func retain(only ids: some Sequence<String>) {
        let remaining = unreadIDs.intersection(ids)
        guard remaining != unreadIDs else { return }
        unreadIDs = remaining
        onChange?()
    }
}

/// Dock のアイコン（テストで差し替える）。
@MainActor
public protocol DockBadging: AnyObject {
    var badgeLabel: String? { get set }
}

extension NSDockTile: DockBadging {}

/// Dock のバッジ。未読のタブの数を出し、0 なら消す。
@MainActor
public final class DockBadge {
    private let tile: any DockBadging

    public init(tile: any DockBadging) {
        self.tile = tile
    }

    /// バッジに出す文字列（0 なら nil）。
    public nonisolated static func label(for count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    public func update(count: Int) {
        let label = Self.label(for: count)
        guard tile.badgeLabel != label else { return }
        tile.badgeLabel = label
    }
}
