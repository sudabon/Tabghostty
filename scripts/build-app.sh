#!/usr/bin/env bash
# build/Tabghostty.app を作る（design D8）。
#
#   make app                                        ../webtabinal をビルドして同梱する
#   WEBTABINAL_DIR=/path/to/webtabinal make app     webtabinal のチェックアウトを指定する
#   WEBTABINAL_DAEMON=/path/to/webtabinal make app  ビルド済みのデーモンを同梱する（webtabinal はビルドしない）
#
# デーモンは Contents/MacOS/webtabinal-daemon として置く。Info.plist の TabghosttyDaemonRevision に、
# 同梱した webtabinal のコミット（ビルド済みのバイナリを使ったときは prebuilt）を記録する。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBTABINAL_DIR="${WEBTABINAL_DIR:-$ROOT/../webtabinal}"
APP_NAME="Tabghostty"
BUNDLE_ID="com.tabghostty.app"
OUTPUT_DIR="$ROOT/build"
APP="$OUTPUT_DIR/$APP_NAME.app"

die() { echo "build-app: $*" >&2; exit 1; }

# 1. デーモンを用意する（Swift のビルドより先に、取得元が無いことを知らせる）。
if [[ -n "${WEBTABINAL_DAEMON:-}" ]]; then
  [[ -f "$WEBTABINAL_DAEMON" && -x "$WEBTABINAL_DAEMON" ]] \
    || die "WEBTABINAL_DAEMON に指定したファイルが無いか、実行できません: $WEBTABINAL_DAEMON"
  DAEMON="$WEBTABINAL_DAEMON"
  DAEMON_REVISION="prebuilt"
elif [[ -f "$WEBTABINAL_DIR/Makefile" && -d "$WEBTABINAL_DIR/cmd/webtabinal" ]]; then
  echo "build-app: webtabinal をビルドします: $WEBTABINAL_DIR"
  make -C "$WEBTABINAL_DIR" build
  DAEMON="$WEBTABINAL_DIR/bin/webtabinal"
  [[ -x "$DAEMON" ]] || die "webtabinal のビルド結果が見つかりません: $DAEMON"
  DAEMON_REVISION="$(git -C "$WEBTABINAL_DIR" rev-parse HEAD 2>/dev/null)" \
    || die "webtabinal のコミットを取得できません: $WEBTABINAL_DIR"
  if [[ -n "$(git -C "$WEBTABINAL_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    DAEMON_REVISION="$DAEMON_REVISION-dirty"
  fi
else
  die "webtabinal のデーモンを用意できません。WEBTABINAL_DAEMON にビルド済みのバイナリを指定するか、WEBTABINAL_DIR に webtabinal のチェックアウトを指定してください（WEBTABINAL_DIR の既定値: $ROOT/../webtabinal）。"
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
echo "build-app: ${APP}（webtabinal: ${DAEMON_REVISION}）"
