#!/usr/bin/env bash
# build/Tabghostty.app を /Applications/Tabghostty.app に置き換える（`make install`。phase7 design D1）。
#
#   make install                                   ビルドしてから置き換える
#   TABGHOSTTY_INSTALL_DIR=~/Applications make install   置き換える先のディレクトリを変える
#
# 起動中の Tabghostty は終了してから置き換える。デーモンは止めない（PTY のセッションはデーモンが持っているので、
# 止めると作業中のシェルが失われる）。新しく同梱したデーモンを使うための手順は、最後に表示する。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Tabghostty"
BUNDLE_ID="com.tabghostty.app"
SOURCE_APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="${TABGHOSTTY_INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
QUIT_TIMEOUT_SECONDS=15

die() { echo "install-app: $*" >&2; exit 1; }

[[ -d "$SOURCE_APP" ]] || die "$SOURCE_APP が見つかりません。先に \`make app\` を実行してください。"
[[ -d "$INSTALL_DIR" ]] || die "置き換える先のディレクトリが見つかりません: $INSTALL_DIR"

is_running() {
  [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" == "true" ]]
}

# 1. 起動中の Tabghostty を終了する（build/ から起動したものも含め、バンドル ID で探す）。
if is_running; then
  echo "install-app: 起動中の $APP_NAME を終了します"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null \
    || die "$APP_NAME を終了できませんでした。手動で終了してから、もう一度実行してください。"
  for ((i = 0; i < QUIT_TIMEOUT_SECONDS * 2; i++)); do
    is_running || break
    sleep 0.5
  done
  is_running && die "$APP_NAME が ${QUIT_TIMEOUT_SECONDS} 秒以内に終了しませんでした。手動で終了してから、もう一度実行してください。"
fi

# 2. 隣にコピーしてから入れ替える（コピーに失敗しても、元のアプリは残る）。
STAGED_APP="$INSTALL_DIR/.$APP_NAME.app.installing"
rm -rf "$STAGED_APP"
trap 'rm -rf "$STAGED_APP"' EXIT
ditto "$SOURCE_APP" "$STAGED_APP" || die "$INSTALL_DIR にコピーできません（書き込みの権限を確認してください）。"
rm -rf "$TARGET_APP"
mv "$STAGED_APP" "$TARGET_APP"

REVISION="$(/usr/libexec/PlistBuddy -c 'Print :TabghosttyDaemonRevision' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"

# 3. デーモンを新しくする手順を案内する（デーモンとセッションはそのまま）。
cat <<EOF
install-app: ${TARGET_APP} を置き換えました（バージョン: ${VERSION}、同梱のデーモン: ${REVISION}）
install-app: デーモンとセッションは止めていません。Tabghostty を起動すると、同じセッションにつながります。

同梱のデーモンを新しくするには、セッションを閉じてよいときに、次を実行してから Tabghostty を起動し直してください
（作業中のシェルは失われます。エージェントのタブは、セッションの復元が有効なら戻ります）。

  pkill -f 'webtabinal-daemon serve'

起動中のデーモンがどのアプリのものかは、\`pgrep -fl 'webtabinal-daemon serve'\` で確かめられます。
同梱しているデーモンは、About ${APP_NAME} の「Bundled daemon」で確かめられます。
EOF
