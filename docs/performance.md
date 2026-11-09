# 性能の計測（Phase 5）

SPEC §7 Phase 5 の完了条件（openspec/changes/phase5-quality-performance の design D8）の計測手順と結果。

| 項目 | 完了条件 | spec |
|---|---|---|
| 入力遅延 | 50 MB の `cat` を流している間も、打ったキーのエコーが 100 ms 以内に出る。Ctrl+C の `0x03` が 100 ms 以内に送られる | terminal-rendering「Responsiveness under heavy output」 |
| 待機中の CPU | 10 タブで 1 分間何もしないときの平均が、1 コアの 1% 未満 | terminal-rendering「Idle efficiency」 |
| メモリ | 30 タブ × scrollback 10000 行のときの値を記録する | design D8 |

## 計測した環境

| 項目 | 値 |
|---|---|
| 機種 | MacBook Pro（Apple M5、メモリ 32 GB） |
| macOS | 26.6.2（25G83） |
| Swift | 6.4（Command Line Tools。Xcode なし） |
| libghostty-vt | 1.0.0（`scripts/libghostty.lock`） |
| 計測日 | 2026-11-09 |

## 結果の一覧

| 項目 | 結果 | 状態 |
|---|---|---|
| 入力遅延（アプリの中の入力の経路） | 50 MB を書き込んでいる端末に送ったキー: 95 パーセンタイル 0.09 ms、最大 0.44 ms（52 回） | 計測済み（下の「アプリを起動せずに測ったもの」） |
| 入力遅延（keyDown からエコーが画面に出るまで） | 100 ms 以内（数値は未記録） | 手動確認 OK（2026-11-09、手順 1） |
| Ctrl+C で止まるまで | 止められた（数値は未記録） | 手動確認 OK（2026-11-09、手順 1） |
| 待機中の CPU（10 タブ、1 分） | 1% 未満（数値は未記録） | 手動確認 OK（2026-11-09、手順 2） |
| メモリ（libghostty、30 端末 × 10000 行） | 293 MB（プロセスの増分 299 MB） | 計測済み（下の「アプリを起動せずに測ったもの」） |
| メモリ（アプリ、30 タブ × 10000 行） | 問題なし（数値は未記録） | 手動確認 OK（2026-11-09、手順 3） |

アプリでの確認（手順 1〜3）は、利用者が手順のとおりに行い、条件を満たした。数値は記録していないので、次に測るときは各節の表を埋める。

## アプリを起動せずに測ったもの

`TABGHOSTTY_BENCH=1` を付けたときだけ実行するテスト（`Tests/TerminalCoreTests/PerformanceMeasurementTests.swift`）で測った。

```bash
TABGHOSTTY_BENCH=1 swift test -c release --filter PerformanceMeasurementTests 2>&1 | grep BENCH
```

（Command Line Tools の Swift では、`make test` と同じく `-Xswiftc -plugin-path -Xswiftc <toolchain>/lib/swift/host/plugins/testing` が要ることがある。Makefile の `SWIFT_TEST_FLAGS` を参照）

| 計測 | 結果（release ビルド） |
|---|---|
| VT への書き込み（31.3 MB、64 KiB ずつ） | 27.6 ms（約 1.1 GB/s） |
| フレームのデコード（JSON + base64、32 KiB の output フレーム 1024 個 = 32 MB） | 48.6 ms（約 0.66 GB/s。`Tests/DaemonClientTests/FrameDecodeMeasurementTests.swift`） |
| 50 MB を書き込んでいる端末に、`enqueueText` してから `input` フレームを送るまで | 52 回、中央値 0.03 ms、95 パーセンタイル 0.09 ms、最大 0.44 ms（書き込み全体は 63 ms） |
| 30 端末（120 列 × 40 行）それぞれに 10100 行を流したとき | libghostty の resident 293 MB、プロセスの footprint の増分 299 MB（スクロールバックは合計 289,950 行。libghostty はページ単位で古い行を消すので、上限の 10000 行より少し少ない） |
| Metal のシェーダーの実行時コンパイル | テストで約 40 ms、`.app` の起動時に 144.7 ms（`makeLibrary(source:)`。起動時にバックグラウンドで行い、その間は Core Text で描く） |

わかったこと:

- 書き込みもデコードも、50 MB で 100 ms 前後で済む。デーモンと PTY を含めた手順 1 でも、入力遅延は 100 ms 以内だった。JSON + base64 の通信のままで完了条件を満たした（design の Risks）。
- 入力の経路について、計測の途中で 1 つ直した。デーモンのフレーム（32 KiB ほど）を積んだまま書き込むと、フレームの中では actor を手放していても、フレームの間で手放していなかったので、50 MB を書き終わるまで入力が送られなかった（43 ms 待った）。フレームの間でも手放すようにした（`TerminalController.drainIncoming`。回帰テストは `HeavyOutputTests.inputIsSentBetweenManySmallFrames`）。
- 受信ループは書き込みを待たない（`SessionCoordinator` は replay / output をそのセッションの端末に積むだけ）。大量の出力を書き込んでいるセッションがあっても、ほかのセッションのエコーのフレームはすぐに読まれる。
- メモリは 30 タブ × 10000 行で約 300 MB（libghostty の分）。アプリ全体でも問題は無かった（手順 3）。今後大きすぎると判断したら、裏のタブを detach する（Phase 3 の Risks）か、`scrollback_lines` を下げるよう案内する。スクロールバックの圧縮（`ghostty_terminal_compress`）も候補（対応表）。

## 手順 1: 入力遅延

1. 50 MB のテキストを作る。

   ```bash
   yes 'drwxr-xr-x  12 user  staff   384 Nov  9 10:52 some-directory-name-here.txt' | head -c 52428800 > /tmp/big.txt
   ```

2. `.app` を作り、計測用の環境変数を付けて起動する。

   ```bash
   make app
   TABGHOSTTY_LATENCY_LOG=1 build/Tabghostty.app/Contents/MacOS/Tabghostty 2>&1 | grep input-latency
   ```

   別のターミナルから `log stream --predicate 'subsystem == "Tabghostty" && category == "latency"'` でも見られる。

3. タブ A で `cat /tmp/big.txt` を実行し、すぐにタブ B に切り替えて、シェルのプロンプトでキーを 100 回以上打つ（キーを押し続けてリピートさせてもよい）。
   - 1 回ごとに `input-latency ms=…`、50 回ごとに `input-latency summary n=… p50=… p95=… max=…` が出る。
   - 計測しているのは、keyDown から、そのあとに受け取った端末の変化（エコー）を描いたフレームを出すまで。
4. タブ A に戻り、`cat` の途中で Ctrl+C を押す。出力が止まり、プロンプトが戻るまでの時間を目で見る（`cat` の出力で毎フレーム画面が変わるので、このタブの `input-latency` の値は Ctrl+C の遅延を表さない）。
5. `TABGHOSTTY_RENDERER=coretext` でも同じように測ると、描画の実装の違いがわかる。

結果: 条件を満たした（利用者の確認、2026-11-09）。数値は未記録

| 描画 | p50 | p95 | max | Ctrl+C |
|---|---|---|---|---|
| Metal | | | | |
| Core Text | | | | |

## 手順 2: 待機中の CPU

1. `.app` を起動し、タブを 10 個開く（それぞれシェルのプロンプトだけ。エージェントや `top` などは動かさない）。
2. ウィンドウを前面に置いたまま（カーソルは点滅している）、何も操作しないで 1 分間待ち、CPU 時間の増分を測る。

   ```bash
   pid=$(pgrep -x Tabghostty)
   t0=$(ps -o cputime= -p "$pid"); sleep 60; t1=$(ps -o cputime= -p "$pid")
   echo "$t0 -> $t1"   # 増分（秒）÷ 60 × 100 が、1 コアに対する平均の CPU 使用率（%）
   ```

   Activity Monitor の「% CPU」を 1 分間見てもよい。
3. ウィンドウを最小化して、同じように測る（隠れている間は描かないので、ほぼ 0 になるはず）。

結果: 条件を満たした（利用者の確認、2026-11-09）。数値は未記録

| 状態 | 平均の CPU 使用率 |
|---|---|
| 前面（点滅あり） | |
| 最小化 | |

## 手順 3: メモリ

1. config の `scrollback_lines` を 10000 にする（設定画面、または config.json）。
2. `.app` を起動し、タブを 30 個開き、それぞれで 10000 行より多く出力する。

   ```bash
   seq 1 12000
   ```

3. メモリを測る。

   ```bash
   footprint -p "$(pgrep -x Tabghostty)"
   ```

   Activity Monitor の「メモリ」の値も記録する。

結果: 条件を満たした（利用者の確認、2026-11-09）。数値は未記録

| 計測 | 値 |
|---|---|
| `footprint` の phys_footprint | |
| Activity Monitor の「メモリ」 | |
