# Design: Phase 5 — 品質と性能

## Context

- Phase 1 の Core Text レンダラーは、RenderState から作った `FrameSnapshot`（dirty 行）を、メインスレッドの `draw(_:)` で描いている。
  - グリフの描画は、`CTLine` を作って描くので重い。
  - 1 フレームでの描画量が増えると、メインスレッドが詰まる。
- 置き換え元の Web 版:
  - 描画は WebGL（Chrome のみ）か DOM。
  - 検索アドオンは読み込んでいるが、UI は無い。
  - リンクは WebLinksAddon を使い、**クリックだけで開く**。
  - 画像は addon-image で、kitty / Sixel / IIP に対応している。
  - DECSET 2026 には対応していない（README の既知の制約）。
- 開発機には Xcode が無く、CLT しかない。CLT には Metal シェーダーのコンパイラ（`metal` / `metallib`）が入っていない。
- macOS 14 以上が前提なので、`NSView.displayLink(target:selector:)` が使える。

## Goals / Non-Goals

**Goals:**

- SPEC §7 Phase 5 の完了条件を満たす。
  - 50 MB を流しても入力が 100 ms 以内に反映される。
  - 待機中の CPU 使用率がほぼ 0%。
  - 30 タブでのメモリ使用量が記録されている。
- 検索、リンク、Kitty Graphics を、ネイティブの UI として提供する。

**Non-Goals:**

- WebSocket のバイナリフレーム化。デーモンの変更が要るので、Phase 6 に移した。Phase 5 は JSON と base64 の通信のままで完了条件を満たすことを目指す。満たせなかった場合は、その結果を Phase 6 の判断材料にする。
- Sixel と iTerm2 IIP。libghostty-vt が提供していない見込みなので、対応外とする（SPEC §9）。
- 合字（ligature）。Web 版も対応していない。

## Decisions

### D1. Metal レンダラーの構成

```
TerminalView (NSView, layer-backed, CAMetalLayer)
 └ MetalRenderer
    ├ GlyphAtlas        Core Text で 1 グリフずつラスタライズ → R8（モノクロ）と RGBA8（カラー絵文字）の 2 枚のテクスチャ
    │                   キーは (font, glyph, scale)。棚詰めで配置し、溢れたら倍に拡張する
    ├ CellBuffers       行ごとに、背景のインスタンス配列とグリフのインスタンス配列を持つ（dirty の行だけを書き換える）
    ├ Pipelines         背景（矩形）/ グリフ（アトラスから取り、前景色で着色）/ 画像（Kitty）/ 装飾（下線、カーソル、選択、IME）
    └ displayLink       vsync のたびに dirty を確認し、無ければ何もしない
```

- 描画は 1 フレームにつき 1 回のコマンドバッファで行い、次の 4 パスで描く。
  1. 背景
  2. 下層の画像
  3. グリフ
  4. 装飾と上層の画像
- コントラストの補正とパレットの解決は、`CellBuffers` を作る段階（CPU 側）で行う。Phase 1 で作った `Palette` と `ContrastAdjuster` をそのまま使う。
- **シェーダーは、Swift の文字列定数として埋め込み、実行時に `device.makeLibrary(source:options:)` でコンパイルする。** CLT には metal コンパイラが無く、SwiftPM のリソースとして `.metal` を処理することができないため。コンパイルは起動時に 1 回、数十 ms 程度かかる。
- Core Text のレンダラーは、`Renderer` プロトコルの別の実装として残す。`TABGHOSTTY_RENDERER=coretext` で切り替える。spec の「Rendering parity」を確認するためと、Metal に問題が出たときの退避先として使う。

**採用しなかった案:**

- `metallib` を事前にビルドする: Xcode が必須になる。
- Core Animation のレイヤーをセルごとに置く: セルの数が数万になると重い。

### D2. 大量出力時の処理の流れ

1. `WSConnection` の受信 Task は、JSON のデコードと base64 のデコードまでをバックグラウンドで行う。
2. `TerminalController`（actor）は、受け取ったデータを最大 64 KiB ずつに区切って VT に書き込む。区切りごとに `Task.yield()` して、入力の送信や resize が後回しにされないようにする。
3. RenderState の更新は、出力ごとには行わない。displayLink の次の tick で 1 回だけ行う。dirty の行が多いときは、全行を作り直す。
4. 入力の送信経路は、出力の処理から独立させる。入力を送るときは `WSConnection.send` を直接呼び、VT への書き込みを待たない。

この流れで 50 MB を流したときの入力遅延を計測し、`docs/performance.md` に記録する。

### D3. 待機時の負荷

- displayLink は、dirty が無いフレームでは何もせずに戻る。さらに、一定時間（例: 1 秒）dirty が無ければ、displayLink を pause にする。出力、入力、カーソルの点滅のいずれかが起きたら再開する。
- カーソルの点滅は、点灯と消灯を切り替えるときだけ dirty にする。約 530 ms に 1 回で済む。
- ウィンドウの `occlusionState` に `.visible` が含まれないときは、描画を止める（点滅も止める）。

### D4. 同期出力（DECSET 2026）

- RenderState（またはモードの問い合わせ）が「同期中」を示している間は、dirty があっても描画を保留する。
- 同期が解除されるか、libghostty のタイムアウトが過ぎたら描画する。タイムアウトがライブラリに無い場合は、Ghostty 本体と同じ 1 秒を Swift 側で持つ。

### D5. 検索

- ライブラリに検索の API がある場合（Phase 0 の対応表で確認）はそれを使う。無い場合は、フォーマッタ（plain）でスクロールバック全体をテキストにし、行ごとに大文字小文字を区別せずに検索する。その場合は、行番号と列の範囲から一致箇所を求める。
- 検索バーは `NSSearchField` を `TerminalView` の上に重ねる。結果の強調は装飾のパイプラインで描く。
- 新しい出力が来たときの再検索は、200 ms のデバウンスをかけて行う。

### D6. リンク

- OSC 8 は、セルのハイパーリンク属性から取り出す。
- 素の URL は、表示されている行（ソフト折り返しは前後の行とつないだもの）から探す。`https?://` の後に、空白・`<`・`>`・`"`・`'`・バッククォート以外の文字が続く範囲を URL とみなし、末尾の約物を取り除く。
- 判定は、Cmd を押している間に限り、マウスが動いたときに遅延して行う。
- 開くのは `NSWorkspace.shared.open` で、スキームが `http` / `https` のときだけにする。
- **Web 版（クリックだけで開く）との違い**:
  - Tabghostty は SPEC §5.1 に従い、Cmd+クリックで開く。マウス報告や選択の操作と衝突させないため。
  - 素のクリックで開かないことは、Phase 7 の README に書く。

### D7. Kitty Graphics

- 画像の本体と配置（位置、サイズ、z-index、クロップ）はライブラリから取り出し、画像 ID ごとに `MTLTexture` を作ってキャッシュする。
- 配置が削除されたら、テクスチャを解放する。
- 描画するときは、配置のセル座標とピクセルのオフセットを viewport に変換し、z の値で上層と下層に振り分ける。
- 裏のタブの画像は、テクスチャを作らずに保持だけしておき、表示したときに作る（メモリを節約するため）。

### D8. 計測の方法（`docs/performance.md`）

| 項目 | 方法 |
|---|---|
| 入力遅延 | 別のタブで `cat big.txt`（50 MB）を流している間に、計測用のビルドでキーを入力し、keyDown → 画面に反映されるまでの時間をログに出す。95 パーセンタイルを記録する |
| 待機中の CPU | `top -pid` / Activity Monitor で 10 タブ・1 分間の平均を取る |
| メモリ | 30 タブ × scrollback 10000 行を埋めた状態の `footprint` / Activity Monitor の値 |

計測した環境（機種、macOS、libghostty-vt のバージョン）も一緒に記録する。

## Risks / Trade-offs

- **[Risk] 実行時にシェーダーをコンパイルすると、起動が少し遅くなる。** → コンパイルは起動時に非同期で始め、終わるまでは Core Text のレンダラーで描く。
- **[Risk] JSON と base64 の通信が律速になり、50 MB で 100 ms を満たせない。** → D2 の分割と yield で、入力の経路だけは確保する。それでも満たせなければ計測結果を記録し、Phase 6 のバイナリフレーム化を進める判断材料にする。
- **[Risk] 30 タブ × 10000 行のメモリ使用量が大きすぎる。** → 計測して判断する。対処の選択肢は、裏のタブを detach すること（Phase 3 の Risks で述べたもの）と、`scrollback_lines` を下げるよう案内すること。
- **[Risk] libghostty-vt に Kitty Graphics の配置を取り出す API が無い、または API が想定と違う。** → Phase 0 の対応表を見て、着手する前に判断する。無ければ inline-images の spec を見直す。
- **[Trade-off] Web 版はクリックだけでリンクを開くが、Tabghostty は Cmd+クリックにする。** 一般的なネイティブのターミナル（iTerm2、Ghostty、Terminal.app）と同じ操作である。
