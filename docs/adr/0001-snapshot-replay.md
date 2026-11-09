# ADR 0001: Terminal Snapshot を使った replay

- ステータス: 提案（2026-11-09）
- 関連: `openspec/changes/phase6-daemon-ghostty-screen`（design D6）、SPEC.md §7 Phase 6
- 計測: `Tests/TerminalCoreTests/SnapshotReplayMeasurementTests.swift`

## 背景

今の replay は、デーモンが持つ PTY 出力のリングバッファ（既定 5 MiB。webtabinal `internal/config` の `RingBufferBytes`）を、attach のたびに 24 KiB ずつ `replay` フレーム（JSON + base64）で送る。最後のフレームだけが `done: true` になる。

リングバッファは古いバイトを区切りを考えずに捨てる。そのため、次の 2 つの問題がある。

- **replay の先頭が壊れる。** エスケープシーケンスや UTF-8 の途中から始まることがある。Tabghostty は壊れた先頭を読み飛ばして続きを処理する（`FixtureStreamTests.truncatedHeadIsTolerated`）。それでも、最初の行が崩れることはある。
- **状態が失われる。** リングバッファより前に送られたシーケンスで設定された状態は、replay では再現されない。たとえば、alternate screen への切り替え、スクロール領域、モード、SGR、タイトルである。

libghostty-vt 1.0.0 には、端末の状態をまるごとバイナリにする Terminal Snapshot（`snapshot.h`）がある。デーモンが端末を持ち、attach のときに Snapshot を送れば、この 2 つの問題を根本から解消できる。この ADR では、その方式を採用するかどうかを決める。実装は Phase 6 の範囲に含めない。

## 検討した方式

| | 方式 | attach でデーモンが送るもの | クライアントの処理 |
|---|---|---|---|
| A | 今のまま | リングバッファのバイト列（`replay`） | 新しい端末に書き込む |
| B | Snapshot | デーモンの端末の Snapshot（新しいバイナリのフレーム `snapshot`） | `ghostty_snapshot_decoder_decode` で端末を復元して、そのまま live に移る |
| C | VT で描き直す | デーモンの端末を、フォーマッタ（`GHOSTTY_FORMATTER_FORMAT_VT`）で VT のシーケンスに作り直したもの（`replay`） | 今と同じく、新しい端末に書き込む |

B と C は、どちらもデーモンが libghostty の端末を持つことが前提になる。具体的には、Phase 6 の D1 で作る `internal/vtscreen/ghostty.go` の端末に、利用者のスクロールバック（`scrollback_lines`、既定 10,000 行）を持たせる。C は D6 の比較項目には無いが、ブラウザ版でも使える案として一緒に測った。

## 計測

### 環境

| 項目 | 値 |
|---|---|
| 機種 | MacBook Pro（Apple M5、メモリ 32 GB） |
| macOS | 26.6.2 |
| ビルド | `swift test -c release`（Swift 6.4、Command Line Tools） |
| libghostty-vt | 1.0.0（`scripts/libghostty.lock`） |
| 計測日 | 2026-11-09 |

### 手順

```sh
TABGHOSTTY_BENCH=1 swift test -c release --filter SnapshotReplayMeasurementTests
```

- **端末の条件**: 120 列 × 40 行の端末に出力を書き込み、`ghostty_snapshot_encode_alloc` でエンコードする。エンコードの前に `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` を有効にしておく（デーモン側で必要な設定）。
- **復元の確認**: 復元した端末と元の端末を VT のフォーマッタ（extras はすべて）で出力し、両者が一致することを `#expect` で確かめた。
- **時間**: エンコードは 5 回、デコードと書き込みは 3 回測った中央値。
- **出力の種類**:
  - 「エージェント風」: コーディングエージェントの TUI に近い出力。SGR の色、日本語、折り返す長い行、スピナーによる同じ行の書き換えを含む。
  - 「ASCII の行」: 80 文字の行が続くもの。

### 結果

| 出力（スクロールバックの上限） | 今の replay（バイト列 / JSON） | Snapshot | エンコード | デコード（履歴を圧縮しながら） | VT で描き直し（C） |
|---|---|---|---|---|---|
| エージェント風 5 MiB（10,000 行） | 5.00 MB / 6.67 MB、書き込み 12.6 ms | **4.57 MB**（バイト列の 91 %） | 1.3 ms | 3.2 ms（4.3 ms） | 0.91 MB、3.7 ms |
| エージェント風 5 MiB（1,000 行） | 5.00 MB / 6.67 MB、書き込み 11.9 ms | 0.48 MB（10 %） | 0.1 ms | 0.3 ms（0.4 ms） | 0.10 MB、0.4 ms |
| ASCII の行 5 MiB（10,000 行） | 5.00 MB / 6.67 MB、書き込み 4.7 ms | 0.77 MB（15 %） | 0.4 ms | 1.3 ms（2.5 ms） | 0.76 MB、1.2 ms |
| エージェント風 64 KiB（10,000 行、411 行を使用） | 0.06 MB / 0.08 MB、書き込み 0.2 ms | 0.20 MB（325 %） | 0.1 ms | 0.1 ms（0.2 ms） | 0.05 MB、0.2 ms |
| フィクスチャ 21 件（4.8 KB） | — | 合計 31.3 KB（最大 2.7 KB） | 平均 0.002 ms | — | — |

デーモンが端末を持つ場合のメモリ（libghostty の `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE`。両方の画面の合計）は次のとおり。

| 出力（スクロールバックの上限） | 端末のメモリ | `ghostty_terminal_compress`（FULL）の後 | 今のリングバッファ |
|---|---|---|---|
| 5 MiB（10,000 行） | 9.77 MB（エージェント風・ASCII ともに同じ） | 0.65 MB | 5 MiB |
| エージェント風 5 MiB（1,000 行） | 1.17 MB | 0.41 MB | 5 MiB |
| エージェント風 64 KiB | 0.78 MB | 0.40 MB | 出力した分（64 KiB） |

壊れたシーケンスの扱いも確かめた（`snapshotRestoresAnUnfinishedSequence`）。

- SGR の途中（`ESC [ 3` まで）や、UTF-8 の途中（`E6 97` まで）でエンコードした Snapshot を復元した。その後に残りのバイトを書き込むと、元の端末と同じ画面とスタイルになった。
- continuation の記録を有効にしていない端末は、シーケンスの途中ではエンコードできない（`GHOSTTY_INVALID_VALUE`。`encodingMidSequenceNeedsContinuationTracking`）。

## 比較（design D6 の項目）

### ブラウザ版との互換性

- **B（Snapshot）**: xterm.js は Snapshot を読めないので、ネイティブ専用のフレームになる。ブラウザ版のために、デーモンはリングバッファも持ち続ける必要がある。さらに、既定のビルド（純 Go、charmbracelet）では Snapshot を作れない。Tabghostty が同梱するデーモン（`daemon/`）は Phase 6 で `ghostty` タグでビルドするようになったが、webtabinal 本体のデーモンは既定のビルドのままである。したがって、どのデーモンでも replay（A）の経路は残る。クライアントは、attach で Snapshot に対応していることを宣言し、デーモンが対応していなければ replay で動く、という二本立てになる。
- **C（VT で描き直す）**: `replay` のまま送れるので、ブラウザ版でも Tabghostty でも使える。

### 大きさと時間

- **時間**: エンコードもデコードも 5 MiB 相当で数 ms で、問題にならない。今の replay をクライアントが書き込む時間（5〜13 ms）と同じくらいである。
- **大きさ（スクロールバック 10,000 行）**: 今の replay と比べて、Snapshot はほとんど小さくならない。エージェント風の出力では、バイト列の 91 % だった。Snapshot は、スタイルの付いたセルや日本語を含むページを、ほぼそのまま持つためである。
  - ASCII の行（15 %）や、スクロールバックが 1,000 行のとき（10 %）は大きく減る。
  - 出力の少ないセッションでは、Snapshot のほうが大きい（64 KiB に対して 0.20 MB）。ページ単位で確保された領域を含むためである。
- **転送量**: Phase 6 のバイナリフレーム（D3）を使えば、今の replay でも JSON + base64 の 6.67 MB が 5.00 MB になる。Snapshot（4.57 MB）との差は小さい。

### replay が壊れたシーケンスから始まる問題

- **B**: 根本から解消する。書きかけのシーケンスも、リングバッファより前に設定された状態（alternate screen、モード、SGR など）も、そのまま復元される。ただし、デーモンの端末で continuation の記録を有効にしておく必要がある。
- **C**: 先頭が壊れる問題は解消する。描き直したシーケンスは端末の状態から作られるためである。一方で、フォーマッタが出力しない状態は再現されない。何が失われるか（Kitty Graphics の画像、書きかけのシーケンスなど）は、採用するときに確かめる必要がある。
- **A**: 今は、Tabghostty が壊れた先頭を読み飛ばすことで実害を抑えている（Phase 1）。

### デーモンのメモリ

- **B と C の前提**: デーモンは、セッションごとに、利用者と同じスクロールバックを持つ端末を保持する。10,000 行では、セッションあたり 9.77 MB になり、今のリングバッファ（5 MiB）の約 2 倍である。30 セッションでは約 290 MB になる。
- **圧縮すると**: アイドル時に `ghostty_terminal_compress` で圧縮すれば 0.65 MB まで減る。ただし、デーモンに圧縮の制御（いつ、どのセッションを圧縮するか）を足すことになる。
- **B の場合**: ブラウザ版のためにリングバッファも残るので、メモリは今より増えるだけになる。
- **D1 との関係**: D1 の端末は、エージェントの状態検出のためのもので、スクロールバックは最小である。B や C のためには、これを 10,000 行に広げることになる。

### そのほかの点

- **フォーマットの安定性**: Snapshot のバイト形式は、ライブラリとは別に版が付く。ABI の約束（`snapshot.h`）の対象外である。デーモンと Tabghostty の libghostty-vt を揃えないと、デコードに失敗する。D5 の一致検証のバージョン照合は、テストの話である。B では、実行時に揃っていることが必須になる。そのため、attach の交渉と、デコードに失敗したら replay に戻る経路が要る。
- **ビルド**: B と C は、デーモンを `ghostty` タグ（cgo と libghostty）でビルドしたときだけ使える。Tabghostty の同梱版（`daemon/`）は、この条件を満たす。Go のバインディングには `Terminal.Snapshot()` があるので、デーモン側で作ることはできる。
- **Tabghostty の実装量（B）**: `VTTerminal` を、復元した `GhosttyTerminal` から作れるようにする必要がある。今は `ghostty_terminal_new` だけである。callback、スクロールバックの上限、Kitty Graphics の設定も、復元した後に設定し直す。さらに、`TerminalController` の phase に Snapshot の受信を足す。

## 結論

**B（Snapshot を使った replay）は、今は採用しない。** 理由は次のとおり。

1. **どのクライアントにも replay は残る。** Snapshot は、ネイティブ専用で、しかも `ghostty` タグでビルドしたデーモンでしか作れない。同梱版は `ghostty` タグでビルドするが、replay（A）の経路は、ブラウザ版にも、webtabinal 本体のデーモン（既定のビルド）につないだ Tabghostty にも残る。Tabghostty も、両方を持つことになる。
2. **得るものが小さい。** 既定のスクロールバック（10,000 行）では、転送量はほとんど減らない（エージェント風の出力で 91 %）。時間の差も数 ms である。転送のオーバーヘッドは、バイナリフレーム（D3 / D4）でほぼ解消できる。
3. **費用が大きい。** デーモンのメモリがセッションあたり約 2 倍になる（圧縮しなければ）。加えて、Snapshot の形式が ABI の約束の対象外なので、デーモンと Tabghostty のバージョンを実行時に揃える仕組みが要る。
4. **今の問題は抑えられている。** replay の先頭が壊れる問題は、Tabghostty の側で実害を抑えられている。状態が失われる問題についても、利用者から報告された例はまだ無い。

### 再検討する条件

次のどれかが起きたら、この ADR を見直す。

- webtabinal 本体のデーモンも `ghostty` タグでビルドするようになり、Tabghostty が replay の経路を持たなくてよくなる（同梱版は Phase 6 で切り替え済み）。
- replay で状態が失われることによる表示の崩れが、実際に問題になる。
- libghostty-vt が Snapshot の形式の互換性を約束する。

見直すときは、まず **C（VT で描き直す）** を検討する。C はブラウザ版でも使え、転送量も小さい（エージェント風の出力で 18 %）。採用する場合は、次の 3 点を確かめる。

- フォーマッタが出力しない状態のうち、何が失われるか
- デーモンのメモリ（スクロールバックを持つ端末と、圧縮の制御）
- D1 の端末にスクロールバックを持たせたとき、エージェントの状態検出への影響

### 採用する場合の注意（B / C 共通）

- **continuation の記録**: デーモンの端末では、作った直後に `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` を有効にする。そうしないと、シーケンスの途中でエンコードできない（B）。
- **復元時の圧縮**: クライアントは `GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY` で復元する。復元した直後のメモリを 9.77 MB から 0.65 MB に抑えられ、時間は 1 ms ほどしか増えない（B）。
- **attach での宣言**: attach で、クライアントが読める Snapshot の形式の版を宣言する。デーモンが対応していない場合や、デコードに失敗した場合は、replay に戻る（B）。
