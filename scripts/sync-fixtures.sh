#!/usr/bin/env bash
# 同梱のデーモン（daemon/）の tests/fixtures/agents を Tests/Fixtures/agents/ へ丸ごとコピーし、
# コピー元のリビジョンを Tests/Fixtures/SOURCE に記録する（design D9、phase6 design D5）。
# フィクスチャのもとは webtabinal（daemon/UPSTREAM.md）。
#
# デーモンが生成した最終画面（screen.txt）と、その生成情報（screen.meta.json）もコピーする（`make screens` が作る）。
# screen.txt が有るのに screen.meta.json が無いフィクスチャがあれば、取り込まずに失敗する
# （一致検証で libghostty-vt のバージョンを照合できないため）。
#
#   bash scripts/sync-fixtures.sh
#   FIXTURES_SOURCE_DIR=/path/to/webtabinal bash scripts/sync-fixtures.sh   ほかのチェックアウトから取り込む
#
# テストはコミット済みのコピーを使うので、取り込み元はこのスクリプトを実行するときだけ要る。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_SOURCE_DIR="${FIXTURES_SOURCE_DIR:-$ROOT/daemon}"
SOURCE_DIR="$FIXTURES_SOURCE_DIR/tests/fixtures/agents"
DEST_PARENT="$ROOT/Tests/Fixtures"
DEST="$DEST_PARENT/agents"

die() { echo "sync-fixtures: $*" >&2; exit 1; }

[[ -d "$SOURCE_DIR" ]] || die "フィクスチャが見つかりません: ${SOURCE_DIR}（FIXTURES_SOURCE_DIR で取り込み元を指定してください）"

REVISION="$(git -C "$FIXTURES_SOURCE_DIR" rev-parse HEAD 2>/dev/null)" || die "取り込み元のコミットを取得できません: $FIXTURES_SOURCE_DIR"
if [[ -n "$(git -C "$FIXTURES_SOURCE_DIR" status --porcelain --untracked-files=all -- tests/fixtures/agents 2>/dev/null)" ]]; then
  REVISION="$REVISION-dirty"
fi
if [[ "$(cd "$FIXTURES_SOURCE_DIR" && pwd)" == "$ROOT/daemon" ]]; then
  REPOSITORY="tabghostty daemon/（フィクスチャのもとは webtabinal。daemon/UPSTREAM.md）"
  SOURCE_PATH="daemon/tests/fixtures/agents"
else
  REPOSITORY="$(git -C "$FIXTURES_SOURCE_DIR" config --get remote.origin.url 2>/dev/null || echo "$FIXTURES_SOURCE_DIR")"
  SOURCE_PATH="tests/fixtures/agents"
fi

mkdir -p "$DEST_PARENT"
TMP="$(mktemp -d "$DEST_PARENT/.agents.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp -R "$SOURCE_DIR/." "$TMP/"

# デーモンの最終画面（screen.txt）と生成情報（screen.meta.json）が対になっているかを確かめる。
SCREENS=0
MISSING_META=()
while IFS= read -r -d '' screen; do
  SCREENS=$((SCREENS + 1))
  dir="$(dirname "$screen")"
  [[ -f "$dir/screen.meta.json" ]] || MISSING_META+=("${dir#"$TMP/"}")
done < <(find "$TMP" -name screen.txt -type f -print0)
if (( ${#MISSING_META[@]} > 0 )); then
  die "screen.txt が有るのに screen.meta.json が無いフィクスチャがあります（取り込みません）: ${MISSING_META[*]}"
fi

rm -rf "$DEST"
mv "$TMP" "$DEST"
trap - EXIT

cat >"$DEST_PARENT/SOURCE" <<EOF
repository: $REPOSITORY
path: $SOURCE_PATH
commit: $REVISION
reference_screens: $SCREENS
EOF

echo "sync-fixtures: ${SOURCE_DIR} (${REVISION}) -> ${DEST}（screen.txt: ${SCREENS} 件）"
