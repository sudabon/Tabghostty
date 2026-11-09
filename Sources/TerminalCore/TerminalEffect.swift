/// 書き込み（またはリサイズ）の処理中に libghostty-vt が出した effect。
///
/// C の callback では値をコピーしてキューに積むだけにし、`ghostty_terminal_vt_write` から戻った後に
/// `VTTerminal.takeEffects()` で取り出す（spec: terminal-engine「Engine responses are delivered after the write completes」）。
/// どう扱うか（送る / 捨てる）は `TerminalController` が phase に応じて決める（design D2）。
public enum TerminalEffect: Equatable, Sendable {
    /// PTY への書き戻し（DA / DSR / サイズ報告 / モード問い合わせ / kitty の応答など）。
    case ptyWrite([UInt8])
    /// BEL（0x07）。
    case bell
    /// OSC 0 / 2 によるタイトルの変更。新しい値はここでは読まない（タブ名はデーモンの cwd / command から作る）。
    case titleChanged
    /// OSC 9 / OSC 777 のデスクトップ通知。通知はデーモンの `notify` フレームに任せるので、表示には使わない。
    case desktopNotification(title: String, body: String)
}
