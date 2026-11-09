#!/usr/bin/env bash
# build/Tabghostty.app を作る（design D8、phase6 design D7）。
#
#   make app                                        daemon/ を ghostty タグでビルドして同梱する（Web 版の画面は ../webtabinal から）
#   WEBTABINAL_DIR=/path/to/webtabinal make app     Web 版の画面をビルドする webtabinal のチェックアウトを指定する
#   WEBTABINAL_DAEMON=/path/to/webtabinal make app  ビルド済みのデーモンを同梱する（daemon/ はビルドしない）
#
# デーモンは Contents/MacOS/webtabinal-daemon として置く。Info.plist の TabghosttyDaemonRevision に、
# 同梱したデーモンの出どころ（tabghostty-<コミット>。ビルド済みのバイナリを使ったときは prebuilt）を記録する。
# webtabinal は Web 版の画面（web/dist。webtabinal では gitignore 済み）のビルドにだけ使い、ソースは変えない。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBTABINAL_DIR="${WEBTABINAL_DIR:-$ROOT/../webtabinal}"
APP_NAME="Tabghostty"
BUNDLE_ID="com.tabghostty.app"
OUTPUT_DIR="$ROOT/build"
APP="$OUTPUT_DIR/$APP_NAME.app"
STATIC_DIST="$ROOT/daemon/internal/static/dist"

die() { echo "build-app: $*" >&2; exit 1; }
warn() { echo "build-app: 警告: $*" >&2; }

# Web 版の画面を daemon/internal/static/dist に置く（無ければプレースホルダの画面のまま）。
prepare_web_ui() {
  find "$STATIC_DIST" -mindepth 1 ! -name .gitkeep -exec rm -rf {} +
  if [[ -f "$WEBTABINAL_DIR/web/package.json" ]]; then
    echo "build-app: Web 版の画面をビルドします: $WEBTABINAL_DIR/web"
    npm --prefix "$WEBTABINAL_DIR/web" run build
    [[ -f "$WEBTABINAL_DIR/web/dist/index.html" ]] || die "Web 版の画面のビルド結果が見つかりません: $WEBTABINAL_DIR/web/dist"
    cp -R "$WEBTABINAL_DIR/web/dist/." "$STATIC_DIST/"
  else
    warn "webtabinal のチェックアウトが無いので、ブラウザ版の画面はプレースホルダになります（WEBTABINAL_DIR で指定できます。既定値: $ROOT/../webtabinal）。"
  fi
}

# 1. デーモンを用意する（Swift のビルドより先に、失敗を知らせる）。
if [[ -n "${WEBTABINAL_DAEMON:-}" ]]; then
  [[ -f "$WEBTABINAL_DAEMON" && -x "$WEBTABINAL_DAEMON" ]] \
    || die "WEBTABINAL_DAEMON に指定したファイルが無いか、実行できません: $WEBTABINAL_DAEMON"
  DAEMON="$WEBTABINAL_DAEMON"
  DAEMON_REVISION="prebuilt"
else
  prepare_web_ui
  echo "build-app: デーモンを daemon/ から ghostty タグでビルドします"
  make -C "$ROOT" daemon
  DAEMON="$ROOT/daemon/bin/webtabinal"
  [[ -x "$DAEMON" ]] || die "デーモンのビルド結果が見つかりません: $DAEMON"
  DAEMON_REVISION="tabghostty-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ -n "$(git -C "$ROOT" status --porcelain -- daemon 2>/dev/null)" ]]; then
    DAEMON_REVISION="$DAEMON_REVISION-dirty"
  fi
fi

# 2. Tabghostty をビルドする。
[[ -d "$ROOT/Vendor/GhosttyVt.xcframework" ]] || die "libghostty-vt が見つかりません。先に \`make deps\` を実行してください。"
swift build -c release --package-path "$ROOT" --product "$APP_NAME"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"
[[ -x "$BIN_DIR/$APP_NAME" ]] || die "ビルド結果が見つかりません: $BIN_DIR/$APP_NAME"

VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# 3. 一時ディレクトリでバンドルを組み立て、できあがってから置き換える。
mkdir -p "$OUTPUT_DIR"
STAGING="$(mktemp -d "$OUTPUT_DIR/.$APP_NAME.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$DAEMON" "$STAGED_APP/Contents/MacOS/webtabinal-daemon"
chmod 755 "$STAGED_APP/Contents/MacOS/$APP_NAME" "$STAGED_APP/Contents/MacOS/webtabinal-daemon"

# 4. Info.plist
cat >"$STAGED_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>TabghosttyDaemonRevision</key>
	<string>$DAEMON_REVISION</string>
</dict>
</plist>
EOF
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

# 5. ad-hoc で署名する（内側の実行ファイルから）。
codesign --force --sign - "$STAGED_APP/Contents/MacOS/webtabinal-daemon"
codesign --force --sign - "$STAGED_APP"

rm -rf "$APP"
mv "$STAGED_APP" "$APP"
echo "build-app: ${APP}（デーモン: ${DAEMON_REVISION}）"
