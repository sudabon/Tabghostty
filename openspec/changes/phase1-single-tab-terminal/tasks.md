# Tasks

> 前提: `phase0-libghostty-foundation` が完了し、archive 済みであること。libghostty-vt の関数は `Sources/TerminalCore/README.md` の対応表にあるものだけを使う。表に無いものが必要になったら、ヘッダを確認して表に追記してから使う。

## 1. DesktopSupport の移植

- [x] 1.1 webtabinal の `desktop/Sources/DesktopSupport.swift` を、そのまま `Sources/DesktopSupport/` に置いて `Package.swift` に追加する。`desktop/Tests/main.swift` のうち、ポートの解析・プローブ応答の判定・デタッチ起動のケースを Swift Testing に移し、`make test` で通ることを確認する
- [x] 1.2 移植したファイルから、WebKit の JS ブリッジ（`javaScriptStringLiteral`、`NotificationBridge`、`*JavaScript` 系）を削る。通知関連は Phase 4 で使うので残す。`make build` と `make test` が通ることを確認する

## 2. VT エンジンの拡張（spec: terminal-engine）

- [x] 2.1 `VTTerminal` に effect キューを入れる。C のコールバックでは積むだけにし、`write()` から戻った後に順に取り出せるようにする。`ESC[c` → DA 応答が 1 件、`ESC[c ESC[6n` → 2 件が順に出ることをテストで確認する
- [x] 2.2 `VTTerminal` に `resize(cols:rows:cellWidthPx:cellHeightPx:)`、`reset()`、最大スクロールバックの設定を追加する。`ESC[16t` の応答にセルのピクセルサイズが入ること、上限 100 行で 500 行を流しても 100 行を超えて見せない（`scrollbackRows` が 100 を超えない。内部にはページ単位で残る。design D2）ことをテストで確認する
- [x] 2.3 `TerminalController`（actor）を作り、VT ハンドルへのアクセスをすべて actor 経由にする。並行して書き込みとリサイズを繰り返してもクラッシュしないことを、Thread Sanitizer（`swift test --sanitize=thread`）付きのテストで確認する
- [x] 2.4 `scripts/sync-fixtures.sh` と `make fixtures` を追加する。`Tests/Fixtures/agents/` と `Tests/Fixtures/SOURCE` を作ってコミットする。全フィクスチャで「一括 / 24 KiB ずつ / 1 バイトずつ」の 3 通りに書き込んで plain テキストが一致すること、先頭を数バイト削った stream でもエラーにならないことを、テストで確認する

## 3. デーモン接続（spec: daemon-connection）

- [x] 3.1 `DaemonConfig` を作る。config.json から port / auth_token / 表示系の設定（font_family、font_size、scrollback_lines、color_scheme）を読み、未知のキーは無視する。既定ポート、`"port": true` / `70000` がエラーになること、エラー文にトークンが含まれないことをテストで確認する
- [x] 3.2 `DaemonLauncher` を作る。手順は、プローブ → 未起動なら `webtabinal-daemon serve` をデタッチ起動（ログは `~/Library/Logs/WebTabinal/daemon.stdio.log`）→ 0.15 秒間隔で最大 15 秒待つ。デーモン以外のプロセスがポートを使っていたら、起動せずにエラーにする。実行ファイルの場所は Bundle 内を探し、`TABGHOSTTY_DAEMON_PATH` で上書きできる。プローブ判定と「デーモン以外が応答した」ケースをテストで確認する
- [x] 3.3 `RESTClient` を作る。すべてのリクエストに Bearer を付け、Host は `127.0.0.1:<port>`、Origin は付けない。`GET /api/config`、`POST /api/sessions`、`POST /api/sessions/{id}/restart` を実装する。モック HTTP サーバーを使って、ヘッダが正しいことと 401 時のエラー文にトークンが含まれないことをテストで確認する
- [x] 3.4 `WSConnection`（actor）を作る。Bearer を付けて接続し、フレームを Codable でエンコード・デコードする（未知のフィールドや種類は無視）。受信ループを回し、`min(500·2^n, 5000)` ms のバックオフで再接続する。モック WS サーバー（`NWListener`）を使って次をテストで確認する
  - 接続できること
  - 未知のフレームが来ても切断しないこと
  - 再接続までの待ち時間の列
  - Origin ヘッダが付かないこと
- [x] 3.5 `SessionStore`（@MainActor）を作る。`sessions` は一覧を丸ごと置き換え、`state` と `agent_state` は該当セッションに反映する。アクティブセッションの選択規則を実装する（spec: tab-operations）。フレームを順に適用したときの一覧の状態と、アクティブセッションが消えたら先頭になることをテストで確認する

## 4. セッションのライフサイクル（spec: terminal-session, terminal-input）

- [x] 4.1 `TerminalController` に phase（detached → replaying → live）、`attach()`（reset してから attach）、replay と output の書き込み、`done` を受けて live に移る処理を実装する。live に移ったら、そのビューのグリッドサイズで `resize` を送る。モック WS で「replay を 3 分割 → done → output」のときに、画面と送信フレームが正しいことをテストで確認する
- [x] 4.2 effect を phase で振り分ける（design D2 の表）。replay 中は PTY 書き戻しを破棄し、live では `input` で送る。OSC 9/99/777、タイトル、ベルは常に破棄する。モック WS で「replay 中の `ESC[c` / `ESC[6n` では `input` が 0 件、live では送信される」ことをテストで確認する（SPEC §8.1）
- [x] 4.3 `attach_overflow` を受けたら reset して attach し直す処理と、再接続時に表示中のセッションを attach し直してサイズを送り直す処理を実装する。モック WS のテストで、内容が重複しないことと、送信フレームの順序を確認する
- [x] 4.4 入力のまとめ送りを実装する。sid ごとに次のランループの周回まで溜めて 1 フレームで送り、replay 中と切断中の入力は捨てる。まとめ送りと、replay 中・切断中に捨てることをテストで確認する
- [x] 4.5 起動時のセッション確保を実装する（spec: tab-operations）。0 件なら作成し、先頭が終了済みなら再起動する。起動時に 1 回だけ行い、再接続では行わない。モックを使って 3 つのシナリオをテストで確認する

## 5. 描画（spec: terminal-rendering）

- [x] 5.1 `FontResolver` を作る（カンマで分割し、引用符を外し、インストール済みのものを探し、`monospace` はシステム等幅フォントにする。太字・斜体の trait、フォールバックのキャッシュも持つ）。`NoSuchFont, Menlo, monospace` → Menlo と、`monospace` → システム等幅フォントになることをテストで確認する
- [x] 5.2 `Palette` を作る（dark / light の fg / bg / cursor / 選択色、ANSI 16 色、256 色の計算式、truecolor）。`ContrastAdjuster`（WCAG の比率 4.5）も作る。パレットの値が design D5 と一致すること、補正後の比率が 4.5 以上になることをテストで確認する
- [x] 5.3 グリッドサイズの計算を作る（4pt のパディング、device pixel への丸め、50 ms のデバウンス、変化が無ければ送らない）。純粋関数の部分をテストで確認する
- [x] 5.4 `TerminalView` に Core Text による描画を実装する。背景の区間、スタイル付きの文字列、全角、下線と打ち消し線、反転、faint、invisible を描き、dirty 行だけを再描画する。`ls --color`、`vim`、`htop`、`claude` を起動して、崩れずに表示されることを目視で確認する（要手動確認）
- [x] 5.5 カーソルを実装する（形状は block / underline / bar、表示と非表示、フォーカス中だけ点滅、非フォーカス時は中抜き）。`printf '\e[6 q'` で bar になること、ウィンドウからフォーカスを外すと中抜きになることを目視で確認する（要手動確認）
- [ ] 5.6 ディスプレイの scale が変わったとき（`viewDidChangeBackingProperties`）に、セル寸法とグリフを計算し直す処理を実装する。Retina ディスプレイと外部モニタの間でウィンドウを移したとき、表示とサイズ報告が正しいことを確認する（要手動確認）
  - 保留（2026-11-09）: Retina でのサイズ報告（`6;33;17`）は確認済み。外部モニタへの移動は、Phase 2 でコピー＆ペーストができるようになってから確認する

## 6. 入力とアプリの外枠（spec: terminal-input, app-shell）

- [x] 6.1 `TerminalView.keyDown` を実装する。`NSEvent` を libghostty のキーイベントに変換し、キーエンコーダを通して `TerminalController` の入力に渡す。Command 付きのキーは送らない。`NSEvent` からの変換表（文字、矢印、Home / End、PageUp / PageDown、Delete、F1〜F12、Ctrl+文字）をテストで確認する。application cursor mode で Up が `ESC O A` になることもテストで確認する
- [x] 6.2 `@main`、`AppDelegate`、メインウィンドウを作る（初期サイズ 1100×720、frame の autosave、タイトルは `<dir> — Tabghostty`、最後のウィンドウを閉じたら終了）。アプリメニュー（About / Hide / Hide Others / Show All / Quit）も作る。タイトルの導出（`~`、`/`、末尾の `/`）をテストで確認する
- [ ] 6.3 起動失敗画面（エラー文と再試行ボタン）とトースト（5 秒で自動的に消え、閉じるボタンあり）を実装する。デーモンを止めた状態で起動すると失敗画面が出て、デーモンを起動してから再試行すると表示されることを確認する（要手動確認）
  - 保留（2026-11-09）: Phase 2 でコピー＆ペーストができるようになってから確認する

## 7. `.app` のビルドとドキュメント（spec: build-system）

- [x] 7.1 `scripts/build-app.sh` と `make app` を実装する（design D8）。次の 3 点を確認する
  - `make app` で `build/Tabghostty.app/Contents/MacOS/webtabinal-daemon` ができ、Info.plist に `TabghosttyDaemonRevision` と `LSMinimumSystemVersion=14.0` が入ること
  - `WEBTABINAL_DAEMON` を指定するとそのバイナリが使われること
  - デーモンの取得元が無いと、2 つの変数名を出して失敗すること
- [x] 7.2 README の「開発環境」に `make app`、`make fixtures`、`WEBTABINAL_DIR`、`WEBTABINAL_DAEMON`、`TABGHOSTTY_DAEMON_PATH` の説明を追記し、書いてある手順で `.app` が作れることを確認する

## 8. 完了条件の確認（SPEC §7 Phase 1）

- [x] 8.1 ブラウザ版（`http://127.0.0.1:8642`）で開いているタブを Tabghostty でも表示し、両方から入力できることを確認する（要手動確認）
- [x] 8.2 `ls --color`、`vim`、`htop`、`claude` が崩れずに表示されることを確認する（要手動確認。5.4 と合わせて確認する）
- [ ] 8.3 ウィンドウのサイズを変えたとき、`stty size` と TUI がそれに追従することを確認する（要手動確認）
  - 保留（2026-11-09）: `stty size` の追従は確認済み（55×128 → 45×117）。TUI（vim / htop）の追従は、Phase 2 でコピー＆ペーストができるようになってから確認する
- [ ] 8.4 デーモンを再起動して自動で再接続されたとき、画面が戻り、シェルの入力行にゴミが入らないことを確認する（要手動確認）
  - 保留（2026-11-09）: Phase 2 でコピー＆ペーストができるようになってから確認する
- [ ] 8.5 5 分間何もしなくても WebSocket が切断されないことを確認する（要手動確認。切断された場合は design の Risk に従い `NWProtocolWebSocket` に切り替える）
  - 保留（2026-11-09）: Phase 2 でコピー＆ペーストができるようになってから確認する
