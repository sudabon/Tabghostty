#!/usr/bin/env bash
# Record a raw PTY fixture for agent-state detection.
# Captures into a temporary directory, validates size/metadata, then promotes.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: record-agent-fixture.sh --agent <id> --version <exact> --scenario <name>
       [--rows N] [--cols N] [--dest DIR] [--overwrite]
       -- <command> [args...]

Records script(1) output as tests/fixtures/agents/<agent>/<version>/<scenario>.
Does not automatically redact secrets; review the transcript before committing.
EOF
}

SCRIPT_NAME="$(basename "$0")"
CAPTURE_TOOL_VERSION="record-agent-fixture/1"
MAX_BYTES="$((512 * 1024))"
AGENT=""
VERSION=""
SCENARIO=""
ROWS="24"
COLS="80"
DEST=""
OVERWRITE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --scenario)
      SCENARIO="${2:-}"
      shift 2
      ;;
    --rows)
      ROWS="${2:-}"
      shift 2
      ;;
    --cols|--columns)
      COLS="${2:-}"
      shift 2
      ;;
    --dest)
      DEST="${2:-}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2
      usage
      exit 2
      ;;
  esac
done

COMMAND=("$@")

if [[ -z "$AGENT" || -z "$VERSION" || -z "$SCENARIO" || ${#COMMAND[@]} -eq 0 ]]; then
  usage
  exit 2
fi

if ! [[ "$ROWS" =~ ^[0-9]+$ && "$ROWS" -ge 1 && "$ROWS" -le 200 ]]; then
  printf '%s: --rows must be 1..200\n' "$SCRIPT_NAME" >&2
  exit 2
fi
if ! [[ "$COLS" =~ ^[0-9]+$ && "$COLS" -ge 1 && "$COLS" -le 500 ]]; then
  printf '%s: --cols must be 1..500\n' "$SCRIPT_NAME" >&2
  exit 2
fi
if [[ "$AGENT" == *"/"* || "$VERSION" == *"/"* || "$SCENARIO" == *"/"* || \
      "$AGENT" == *".."* || "$VERSION" == *".."* || "$SCENARIO" == *".."* ]]; then
  printf '%s: agent, version, and scenario must be single path segments\n' "$SCRIPT_NAME" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "$DEST" ]]; then
  DEST="$ROOT/tests/fixtures/agents"
fi
TARGET="$DEST/$AGENT/$VERSION/$SCENARIO"

print_review_checklist() {
  cat >&2 <<'EOF'
Manual review required before commit:
  [ ] credentials / API tokens / cookies
  [ ] private source code
  [ ] usernames
  [ ] absolute home paths (/Users/..., /home/...)
Automatic redaction is not applied because it can break terminal control sequences.
Review with: webtabinal state snapshot <session-id>
             and an escaped / hex dump of stream.raw
EOF
}

warn_secrets() {
  cat >&2 <<'EOF'
WARNING: the transcript may contain prompts, repository paths, usernames, tokens,
and source code. Capture a controlled, isolated scenario.
EOF
}

detect_script() {
  local script_bin="${WEBTABINAL_SCRIPT_BIN:-script}"
  if ! command -v "$script_bin" >/dev/null 2>&1; then
    printf '%s: script(1) not found. Install BSD script (macOS) or util-linux script.\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
  local flavor="${WEBTABINAL_SCRIPT_FLAVOR:-}"
  if [[ -z "$flavor" ]]; then
    local ident
    ident="$("$script_bin" --version 2>&1 || true)"
    if printf '%s' "$ident" | grep -qi 'util-linux'; then
      flavor="util-linux"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
      flavor="bsd"
    else
      printf '%s: unsupported script(1) on this platform.\n' "$SCRIPT_NAME" >&2
      printf 'Need BSD script (macOS) or util-linux script. Detected: %s\n' "$ident" >&2
      exit 1
    fi
  fi
  case "$flavor" in
    bsd|util-linux) ;;
    *)
      printf '%s: unknown script flavor %s (bsd or util-linux)\n' "$SCRIPT_NAME" "$flavor" >&2
      exit 1
      ;;
  esac
  SCRIPT_BIN="$script_bin"
  SCRIPT_FLAVOR="$flavor"
}

if [[ -e "$TARGET" && "$OVERWRITE" != "1" ]]; then
  printf '%s: destination exists: %s\n' "$SCRIPT_NAME" "$TARGET" >&2
  printf 'Pass --overwrite to replace it. Existing files were left unchanged.\n' >&2
  exit 1
fi

detect_script
warn_secrets

TMPDIR_CAPTURE="$(mktemp -d "${TMPDIR:-/tmp}/webtabinal-fixture.XXXXXX")"
cleanup() {
  if [[ -n "${TMPDIR_CAPTURE:-}" && -d "$TMPDIR_CAPTURE" ]]; then
    rm -rf "$TMPDIR_CAPTURE"
  fi
}
trap cleanup EXIT INT TERM

STREAM_OUT="$TMPDIR_CAPTURE/stream.raw"
META_OUT="$TMPDIR_CAPTURE/metadata.json"
CASE_OUT="$TMPDIR_CAPTURE/case.json"

export TERM="${TERM:-xterm-256color}"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export COLUMNS="$COLS"
export LINES="$ROWS"

set +e
case "$SCRIPT_FLAVOR" in
  bsd)
    "$SCRIPT_BIN" -q "$STREAM_OUT" "${COMMAND[@]}"
    STATUS=$?
    ;;
  util-linux)
    quoted=""
    printf -v quoted '%q ' "${COMMAND[@]}"
    "$SCRIPT_BIN" -q -e -c "$quoted" "$STREAM_OUT"
    STATUS=$?
    ;;
esac
set -e

if [[ "$STATUS" -ne 0 ]]; then
  printf '%s: capture command exited %s; destination unchanged\n' "$SCRIPT_NAME" "$STATUS" >&2
  exit "$STATUS"
fi
if [[ ! -f "$STREAM_OUT" ]]; then
  printf '%s: script(1) did not create an output file; destination unchanged\n' "$SCRIPT_NAME" >&2
  exit 1
fi

SIZE="$(wc -c < "$STREAM_OUT" | tr -d ' ')"
if [[ "$SIZE" -gt "$MAX_BYTES" ]]; then
  printf '%s: capture is %s bytes (limit %s). Record a smaller controlled scenario. Destination unchanged.\n' \
    "$SCRIPT_NAME" "$SIZE" "$MAX_BYTES" >&2
  exit 1
fi

python3 - "$META_OUT" "$CASE_OUT" "$AGENT" "$VERSION" "$SCENARIO" "$ROWS" "$COLS" "$TERM" "${LANG}" "$(uname -s)" "$CAPTURE_TOOL_VERSION" "$SIZE" <<'PY'
import json, sys
meta_path, case_path, agent, version, scenario, rows, cols, term, locale, platform, tool, size = sys.argv[1:]
meta = {
    "schema_version": 1,
    "agent": agent,
    "version": version,
    "scenario": scenario,
    "rows": int(rows),
    "columns": int(cols),
    "term": term,
    "locale": locale,
    "platform": platform.lower(),
    "capture_tool_version": tool,
    "reviewed": False,
    "notes": "Unreviewed capture. Set reviewed=true after secret review and fill case.json steps.",
}
case = {
    "schema_version": 1,
    "identity": {"command": agent},
    "steps": [{
        "name": "capture",
        "byte_start": 0,
        "byte_end": int(size),
        "advance_ms": 1620,
        "output_bytes": min(int(size), 40),
        "expect": {
            "agent_id": agent,
            "state": "idle",
            "signal": "screen",
            "change_count": 1
        }
    }]
}
open(meta_path, "w", encoding="utf-8").write(json.dumps(meta, indent=2) + "\n")
open(case_path, "w", encoding="utf-8").write(json.dumps(case, indent=2) + "\n")
PY

mkdir -p "$(dirname "$TARGET")"
if [[ -e "$TARGET" && "$OVERWRITE" == "1" ]]; then
  rm -rf "$TARGET"
fi
mkdir -p "$TARGET"
cp "$STREAM_OUT" "$TARGET/stream.raw"
cp "$META_OUT" "$TARGET/metadata.json"
cp "$CASE_OUT" "$TARGET/case.json"

printf 'Recorded %s (%s bytes)\n' "$TARGET" "$SIZE" >&2
print_review_checklist
printf '%s\n' "$TARGET"
