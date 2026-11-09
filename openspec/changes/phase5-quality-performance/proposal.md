# Proposal: Phase 5 — 品質と性能（Metal 描画・検索・リンク・Kitty Graphics）

## Why

Phase 4 までで、機能は現行 `.app` と同じになった。ただし Phase 1 の Core Text による描画は、正しさを優先して作ったもので、性能には次の不安がある。

- 大量の出力（ログを流す、`cat` で大きなファイルを表示する）で UI が固まるおそれがある。
- 何もしていないときにも CPU を使っているおそれがある。

SPEC.md §7 Phase 5 は、次の 3 点を求めている。

- Metal による描画で性能の完了条件（50 MB を流しても入力が 100 ms 以内に反映される、待機中の CPU 使用率がほぼ 0%）を満たすこと。
- 検索とハイパーリンクを追加すること。Web 版の xterm.js にあったのはアドオンだけで、UI は無かった。
- Kitty Graphics を描画すること。

## What Changes

- **Metal レンダラー**
  - グリフアトラス（モノクロとカラー絵文字）を作る。
  - 背景のパスとグリフのパスに分けて、インスタンス描画する。
  - dirty の行だけを更新する。
  - `NSView.displayLink` で vsync に同期し、dirty が無いフレームは描画しない。
  - Core Text のレンダラーは、比較とデバッグのために残し、環境変数で切り替えられるようにする。
- **同期出力**
  - DECSET 2026 に対応する（アプリが更新している途中の画面を表示しない）。
- **大量出力時の応答性**
  - 受信した出力を区切りながら処理し、入力と描画の処理が後回しにされないようにする。
- **検索**
  - Cmd+F で検索バーを開く。対象はスクロールバックを含む全体。
  - 一致箇所を強調し、Cmd+G / Cmd+Shift+G で前後に移動し、件数を表示する。
- **ハイパーリンク**
  - OSC 8 のリンクと、表示行に含まれる素の http(s) URL を対象にする。
  - Cmd を押しながらホバーすると下線を引き、Cmd+クリックで既定のブラウザで開く。
- **Kitty Graphics**
  - 画像と配置をライブラリから取り出し、テクスチャとして描く。
  - Sixel と iTerm2 IIP には対応しない。受け取っても無視し、表示は壊さない。
- **性能の計測**
  - 次の手順と結果を `docs/performance.md` に記録する。
    - 50 MB を流したときの入力遅延
    - 待機中の CPU 使用率
    - 30 タブ × scrollback 10000 行でのメモリ使用量

SPEC §7 Phase 5 の任意項目 4（WebSocket のバイナリフレーム化）は、デーモンの変更が必要になる。そのため、Tabghostty をクライアント専用にするという方針に合わせて、Phase 6 の change（`phase6-daemon-ghostty-screen`）に移した。

## Capabilities

### New Capabilities

- `terminal-search`: 検索バー、検索範囲、強調表示、前後への移動、件数。
- `terminal-links`: OSC 8 と URL の検出、Cmd を押しながらのホバーとクリック、開いてよいスキーム。
- `inline-images`: Kitty Graphics の表示と、Sixel / IIP を受け取ったときの扱い。

### Modified Capabilities

Phase 4 の change を先に archive しておくこと。

- `terminal-rendering`: 性能（大量出力時の応答性、待機中の負荷、vsync への同期）と、同期出力（DECSET 2026）を追加する。

## Impact

- `TerminalUI` に `MetalRenderer`、`GlyphAtlas`、シェーダー（`.metal`。SwiftPM のリソースとして持つ）、`SearchBar`、`LinkDetector` を追加する。
- `TerminalCore` に、検索、Kitty Graphics、ハイパーリンク属性のラッパーを追加する。
- `docs/performance.md` を新しく作る。
- CLT だけの環境で Metal シェーダーをビルドする方法を確認する必要がある。ソースから実行時にコンパイルする代案を design.md に書く。
- webtabinal（デーモン・web）は変更しない。
