#!/usr/bin/env bash
# webtabinal の tests/fixtures/agents を Tests/Fixtures/agents/ へ丸ごとコピーし、
# コピー元のコミットを Tests/Fixtures/SOURCE に記録する（design D9）。
#
#   WEBTABINAL_DIR=/path/to/webtabinal bash scripts/sync-fixtures.sh
#
# WEBTABINAL_DIR の既定値は、このリポジトリと同じ階層の ../webtabinal。
# テストはコミット済みのコピーを使うので、webtabinal のチェックアウトはこのスクリプトを実行するときだけ要る。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBTABINAL_DIR="${WEBTABINAL_DIR:-$ROOT/../webtabinal}"
SOURCE_DIR="$WEBTABINAL_DIR/tests/fixtures/agents"
DEST_PARENT="$ROOT/Tests/Fixtures"
DEST="$DEST_PARENT/agents"

die() { echo "sync-fixtures: $*" >&2; exit 1; }

[[ -d "$SOURCE_DIR" ]] || die "webtabinal のフィクスチャが見つかりません: ${SOURCE_DIR}（WEBTABINAL_DIR で webtabinal のチェックアウトを指定してください）"

REVISION="$(git -C "$WEBTABINAL_DIR" rev-parse HEAD 2>/dev/null)" || die "webtabinal のコミットを取得できません: $WEBTABINAL_DIR"
if [[ -n "$(git -C "$WEBTABINAL_DIR" status --porcelain -- tests/fixtures/agents 2>/dev/null)" ]]; then
  REVISION="$REVISION-dirty"
fi

mkdir -p "$DEST_PARENT"
TMP="$(mktemp -d "$DEST_PARENT/.agents.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cp -R "$SOURCE_DIR/." "$TMP/"
rm -rf "$DEST"
mv "$TMP" "$DEST"
trap - EXIT

cat >"$DEST_PARENT/SOURCE" <<EOF
repository: https://github.com/sudabon/webtabinal
path: tests/fixtures/agents
commit: $REVISION
EOF

echo "sync-fixtures: $SOURCE_DIR ($REVISION) -> $DEST"
