package main

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/sudabon/webtabinal/internal/paths"
)

// hookSnippet is a paste-ready configuration fragment for one coding agent.
// Nothing here reads or writes the agent's file: these files are shared with
// other tools and can already hold an unrelated entry in the same slot, so the
// merge is the user's call.
type hookSnippet struct {
	// path is where the fragment belongs, written the way a user would type it.
	path string
	// note explains what the fragment cannot say on its own.
	note string
	// body renders the fragment for a resolved daemon binary path.
	body func(bin string) string
}

func hookSnippets() map[string]hookSnippet {
	return map[string]hookSnippet{
		"claude": {
			path: "~/.claude/settings.json",
			note: "hook は制御端末を持たないため、OSC を端末へ直接書く方法は使えません。" + paths.CLIName + " notify が loopback API 経由で届けます。",
			body: func(bin string) string {
				return `{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": ` + jsonString(bin+` notify --title 'Claude Code'`) + ` }
        ]
      }
    ]
  }
}`
			},
		},
		"cursor-agent": {
			path: "~/.cursor/hooks.json",
			note: "cursor-agent の hook は対話セッションでのみ発火します（`-p` のヘッドレス実行では発火しません）。",
			body: func(bin string) string {
				return `{
  "version": 1,
  "hooks": {
    "stop": [
      { "type": "command", "command": ` + jsonString(bin+` notify --title 'Cursor Agent'`) + ` }
    ]
  }
}`
			},
		},
		"codex": {
			path: "~/.codex/config.toml",
			note: "Codex は hook を必要としません。ターン完了時に Codex 自身が OSC 9 を端末へ書くので、WebTabinal はそれを拾います。",
			body: func(string) string {
				return `[tui]
notifications = ["agent-turn-complete", "approval-requested"]
notification_method = "osc9"`
			},
		},
	}
}

func hookAgentNames() []string {
	names := make([]string, 0, len(hookSnippets()))
	for name := range hookSnippets() {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func hooksUsage() string {
	return fmt.Sprintf("usage: %s hooks print <%s>", paths.CLIName, strings.Join(hookAgentNames(), "|"))
}

// runHooksPrint prints the fragment for one agent. bin is the absolute path of
// this binary, so the pasted command works without webtabinal being on PATH.
func runHooksPrint(wOut, wErr io.Writer, args []string, bin string) int {
	if len(args) != 2 || args[0] != "print" {
		fmt.Fprintf(wErr, "%s\n", hooksUsage())
		return 2
	}
	snippet, ok := hookSnippets()[args[1]]
	if !ok {
		fmt.Fprintf(wErr, "unsupported agent %q\n", args[1])
		fmt.Fprintf(wErr, "supported: %s\n", strings.Join(hookAgentNames(), ", "))
		return 2
	}
	fmt.Fprintf(wOut, "# %s に貼り付けてください（このコマンドは設定ファイルを読み書きしません）\n", snippet.path)
	fmt.Fprintf(wOut, "# %s\n", snippet.note)
	fmt.Fprintf(wOut, "%s\n", snippet.body(bin))
	return 0
}

// jsonString quotes a value for embedding in the printed JSON fragments, so a
// binary path holding a quote or backslash still yields pasteable JSON.
func jsonString(s string) string {
	quoted, err := json.Marshal(s)
	if err != nil {
		return `""`
	}
	return string(quoted)
}
