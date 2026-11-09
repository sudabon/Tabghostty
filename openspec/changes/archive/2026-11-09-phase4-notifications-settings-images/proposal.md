# Proposal: Phase 4 — 通知・設定画面・画像添付・配色

## Why

Phase 3 まででタブの管理はできるようになった。しかし、次の機能がまだ無い。

- 通知（コマンドの完了、エージェントの待ち）
- 設定画面
- 画像添付
- system の配色への追従

これらが揃わないと、現行の WebTabinal.app を置き換えられない。SPEC.md §7 Phase 4 は、ここまでで「ネイティブ版が現行 `.app` の機能を満たす」状態にし、1 週間ほど日常的に使い込むことを求めている。

## What Changes

- **通知**: webtabinal `web/src/notify.ts` と `App.tsx` の判定を移植する。
  - 対象は、コマンドの完了（`running → idle`）と、`notify` フレーム（OSC 9/99/777、画面の検知、hook）。
  - 判定の順序は Web 版と同じにする。
    1. `enabled`
    2. アクティブかつフォーカス中なら、`always` が無効のときは出さない
    3. 完了の場合は `min_duration_ms`
    4. 未読
    5. ミュート
    6. `commands` の basename での絞り込み
  - 表示は、旧 `desktop/` の `NativeNotificationService` を使う。音は鳴らさない。アプリが前面にあるときも、バナーとリストに出す。
  - 通知をクリックすると、そのタブをアクティブにする。
  - 通知の許可は、設定画面の操作からだけ求める。
- **設定画面**（`NSWindow`。Cmd+, とサイドバーの「設定」から開く）: Web 版の 4 カテゴリをそのまま移す。
  - 外観、一般、通知、キーボード。
  - 変更するたびに `PATCH /api/config` を送る。失敗したら元に戻し、エラーを出す。
  - キーの記録、コマンドのチップ、エージェント状態の詳細設定、許可の状態を表示する。
- **設定の反映**: `GET /api/config` を読み直して、変わった値を即座に反映する。
  - 読み直すのは、アプリが前面に来たとき、設定画面を開いたとき、再接続したとき。
  - デーモンは config の変化を通知しないので、ブラウザ版で変えた設定を拾うにはこの方法しかない。
- **画像添付**
  - Cmd+V で、pasteboard に画像（PNG、TIFF → PNG に変換）があれば、テキストより優先して添付する。
  - 画像ファイルのドロップに対応する。ドロップを受け付ける間は、点線の枠を出す。
  - `POST /api/sessions/{id}/images` に生のバイト列を順に送り、返ってきた `path` をバックスラッシュでエスケープしてから、スペースで区切ってペーストする。
  - 失敗した画像は飛ばす。アップロード中にタブが切り替わったら、ペーストしない。
- **配色**
  - `color_scheme` が `system` のときは、`NSApp.effectiveAppearance` を監視して、即座に切り替える。
  - 設定画面での変更は、楽観的に反映し、失敗したら戻す。
  - ターミナルとサイドバーなど周囲の UI の両方に適用する。

## Capabilities

### New Capabilities

- `notifications`: バナーを出すかの判定、内容、配信、クリックしたときの動作、許可。
- `settings-window`: 設定画面の構成、各項目、即時保存、検証と巻き戻し、他のクライアントでの変更を拾うこと。
- `image-attach`: 画像のペーストとドロップ、アップロード、パスの入力。
- `color-scheme`: light / dark / system の解決と、動的な切り替え。

### Modified Capabilities

Phase 3 の change を先に archive しておくこと。

- `terminal-clipboard`: 「Paste with Command-V」を変更する。pasteboard に画像があれば、テキストより優先して画像を添付する。

## Impact

- `Shell` に、次を追加する。
  - NotificationCoordinator
  - SettingsWindowController（4 つのペイン）
  - KeyRecorder
  - ImageAttachService
  - AppearanceObserver
- `DesktopSupport` の `NativeNotificationService`、`NotificationActivationCoordinator`、`foregroundNotificationPresentationOptions` を使う。
- `DaemonClient`: 画像のアップロードを追加し、config の読み直しと、変わった値の配布を行う。
- `TerminalUI`: ドロップを受け付ける。パレットを動的に切り替える。
- テストを移植する: webtabinal `web/tests` の `notify.test.ts`、`notification-provider.test.ts`（ネイティブ版に当てはまる部分）、`image-attach.test.ts`、`settings-modal.test.ts`、`theme.test.ts`、`app.test.ts` の該当分。
- 通知を使うには、`.app` として起動する必要がある（`UNUserNotificationCenter` の制約）。
- webtabinal（デーモン・web）は変更しない。
