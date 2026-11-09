#!/usr/bin/env bash
# libghostty-vt の XCFramework を取得・検証して Vendor/GhosttyVt.xcframework に置く。
#
#   bash scripts/fetch-libghostty.sh         lock の SHA-256 と minisign 署名で検証して配置する
#   bash scripts/fetch-libghostty.sh --pin   署名を検証した SHA256SUMS から lock の SHA-256 を書き込む
#
# 検証に失敗したときは非ゼロで終了し、Vendor/ に新しい成果物を残さない。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/scripts/libghostty.lock"
VENDOR="$ROOT/Vendor"
TARGET="$VENDOR/GhosttyVt.xcframework"
STAMP_NAME=".tabghostty-verified"

die() { echo "fetch-libghostty: $*" >&2; exit 1; }

# shellcheck source=libghostty.lock
source "$LOCK"
: "${LIBGHOSTTY_VERSION:?lock に LIBGHOSTTY_VERSION がありません}"
: "${LIBGHOSTTY_BASE_URL:?lock に LIBGHOSTTY_BASE_URL がありません}"
: "${LIBGHOSTTY_ARTIFACT:?lock に LIBGHOSTTY_ARTIFACT がありません}"
: "${LIBGHOSTTY_MINISIGN_PUBKEY:?lock に LIBGHOSTTY_MINISIGN_PUBKEY がありません}"

WORK=""
cleanup() { if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

prepare() { # ダウンロードと検証に必要なツールと作業ディレクトリを用意する
  command -v curl >/dev/null || die "curl が見つかりません"
  command -v shasum >/dev/null || die "shasum が見つかりません"
  command -v minisign >/dev/null \
    || die "minisign が見つかりません。\`brew install minisign\` でインストールしてください（上流の署名検証に必要）"
  mkdir -p "$VENDOR/tmp"
  WORK="$(mktemp -d "$VENDOR/tmp/fetch.XXXXXX")"
}

download() { # url dest
  curl -fsSL --retry 2 -o "$2" "$1" || die "ダウンロードに失敗しました: $1"
}

verify_signature() { # file（同じディレクトリに file.minisig があること）
  minisign -V -q -P "$LIBGHOSTTY_MINISIGN_PUBKEY" -m "$1" >/dev/null \
    || die "minisign 署名の検証に失敗しました: $(basename "$1")"
}

if [[ "${1:-}" == "--pin" ]]; then
  prepare
  download "$LIBGHOSTTY_BASE_URL/SHA256SUMS" "$WORK/SHA256SUMS"
  download "$LIBGHOSTTY_BASE_URL/SHA256SUMS.minisig" "$WORK/SHA256SUMS.minisig"
  verify_signature "$WORK/SHA256SUMS"
  sum="$(awk -v f="$LIBGHOSTTY_ARTIFACT" '{ n=$2; sub(/^\*/, "", n) } n == f { print $1 }' "$WORK/SHA256SUMS")"
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "SHA256SUMS に $LIBGHOSTTY_ARTIFACT の行がありません"
  sed -i '' "s/^LIBGHOSTTY_SHA256=.*/LIBGHOSTTY_SHA256=$sum/" "$LOCK"
  echo "fetch-libghostty: $LIBGHOSTTY_ARTIFACT の SHA-256 を lock に書き込みました: $sum"
  exit 0
fi

[[ "${LIBGHOSTTY_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
  || die "lock の LIBGHOSTTY_SHA256 が未設定です。\`bash scripts/fetch-libghostty.sh --pin\` で設定してください"

stamp_value="$LIBGHOSTTY_VERSION $LIBGHOSTTY_SHA256"
if [[ -f "$TARGET/$STAMP_NAME" && "$(cat "$TARGET/$STAMP_NAME")" == "$stamp_value" ]]; then
  echo "fetch-libghostty: libghostty-vt $LIBGHOSTTY_VERSION は検証済みで配置済みです"
  exit 0
fi

prepare
archive="$WORK/$LIBGHOSTTY_ARTIFACT"
echo "fetch-libghostty: $LIBGHOSTTY_BASE_URL/$LIBGHOSTTY_ARTIFACT を取得します"
download "$LIBGHOSTTY_BASE_URL/$LIBGHOSTTY_ARTIFACT" "$archive"
download "$LIBGHOSTTY_BASE_URL/$LIBGHOSTTY_ARTIFACT.minisig" "$archive.minisig"

actual="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
[[ "$actual" == "$LIBGHOSTTY_SHA256" ]] \
  || die "SHA-256 が一致しません（期待値 ${LIBGHOSTTY_SHA256}、実際 ${actual}）"
verify_signature "$archive"

mkdir "$WORK/extract"
ditto -x -k "$archive" "$WORK/extract"
found="$(find "$WORK/extract" -maxdepth 2 -type d -name '*.xcframework' | head -n 1)"
[[ -n "$found" ]] || die "アーカイブに .xcframework がありません"
echo "$stamp_value" > "$found/$STAMP_NAME"

# 既存のものと入れ替える（新しいものを置いてから古いものを消す）
if [[ -e "$TARGET" ]]; then mv "$TARGET" "$WORK/previous.xcframework"; fi
mv "$found" "$TARGET"
echo "fetch-libghostty: libghostty-vt $LIBGHOSTTY_VERSION を $TARGET に配置しました"
