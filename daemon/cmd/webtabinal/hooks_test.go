package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func printHooks(t *testing.T, args []string) (string, string, int) {
	t.Helper()
	var out, errBuf strings.Builder
	code := runHooksPrint(&out, &errBuf, args, "/opt/webtabinal/bin/webtabinal")
	return out.String(), errBuf.String(), code
}

func TestHooksPrintClaudeCode(t *testing.T) {
	out, errBuf, code := printHooks(t, []string{"print", "claude"})
	if code != 0 {
		t.Fatalf("exit %d stderr %s", code, errBuf)
	}
	if !strings.Contains(out, "~/.claude/settings.json") {
		t.Fatalf("missing the target path:\n%s", out)
	}
	snippet := jsonBlock(t, out)
	hooks, _ := snippet["hooks"].(map[string]any)
	stop, _ := hooks["Stop"].([]any)
	if len(stop) != 1 {
		t.Fatalf("Stop entries = %#v", hooks["Stop"])
	}
	inner, _ := stop[0].(map[string]any)["hooks"].([]any)
	if len(inner) != 1 {
		t.Fatalf("inner hooks = %#v", stop[0])
	}
	entry, _ := inner[0].(map[string]any)
	if entry["type"] != "command" {
		t.Fatalf("type = %#v", entry["type"])
	}
	command, _ := entry["command"].(string)
	if !strings.HasPrefix(command, "/opt/webtabinal/bin/webtabinal notify") {
		t.Fatalf("command = %q, want the resolved binary path", command)
	}
}

func TestHooksPrintCursorAgent(t *testing.T) {
	out, errBuf, code := printHooks(t, []string{"print", "cursor-agent"})
	if code != 0 {
		t.Fatalf("exit %d stderr %s", code, errBuf)
	}
	if !strings.Contains(out, "~/.cursor/hooks.json") {
		t.Fatalf("missing the target path:\n%s", out)
	}
	// cursor-agent fires hooks only in an interactive session, which is easy to
	// trip over when testing with `-p`.
	if !strings.Contains(out, "対話") {
		t.Fatalf("missing the interactive-only caveat:\n%s", out)
	}
	snippet := jsonBlock(t, out)
	if snippet["version"] != float64(1) {
		t.Fatalf("version = %#v, want 1", snippet["version"])
	}
	hooks, _ := snippet["hooks"].(map[string]any)
	stop, _ := hooks["stop"].([]any)
	if len(stop) != 1 {
		t.Fatalf("stop entries = %#v", hooks["stop"])
	}
	entry, _ := stop[0].(map[string]any)
	if entry["type"] != "command" {
		t.Fatalf("type = %#v", entry["type"])
	}
	command, _ := entry["command"].(string)
	if !strings.HasPrefix(command, "/opt/webtabinal/bin/webtabinal notify") {
		t.Fatalf("command = %q, want the resolved binary path", command)
	}
}

// Codex reports turn completion over OSC 9 on its own, so there is no hook to
// install; only its TUI settings matter.
func TestHooksPrintCodexHasNoHook(t *testing.T) {
	out, errBuf, code := printHooks(t, []string{"print", "codex"})
	if code != 0 {
		t.Fatalf("exit %d stderr %s", code, errBuf)
	}
	if !strings.Contains(out, "~/.codex/config.toml") {
		t.Fatalf("missing the target path:\n%s", out)
	}
	if !strings.Contains(out, "[tui]") || !strings.Contains(out, "notification_method") {
		t.Fatalf("missing the tui settings:\n%s", out)
	}
	if strings.Contains(out, "notify") {
		t.Fatalf("codex needs no webtabinal notify hook:\n%s", out)
	}
}

func TestHooksPrintRejectsUnsupportedAgent(t *testing.T) {
	out, errBuf, code := printHooks(t, []string{"print", "aider"})
	if code == 0 {
		t.Fatal("expected a non-zero exit for an unsupported agent")
	}
	for _, name := range []string{"claude", "codex", "cursor-agent"} {
		if !strings.Contains(errBuf, name) {
			t.Fatalf("stderr does not list %s:\n%s", name, errBuf)
		}
	}
	if out != "" {
		t.Fatalf("stdout = %q, want nothing printed", out)
	}
}

func TestHooksPrintRejectsBadUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"print"}, {"apply", "claude"}, {"print", "claude", "extra"}} {
		out, errBuf, code := printHooks(t, args)
		if code == 0 {
			t.Fatalf("args %v: expected a usage error", args)
		}
		if errBuf == "" {
			t.Fatalf("args %v: expected usage on stderr", args)
		}
		if out != "" {
			t.Fatalf("args %v: stdout = %q, want nothing printed", args, out)
		}
	}
}

// The snippet is advice, not automation: these files are shared with other
// tools and can already hold an unrelated entry in the same slot.
func TestHooksPrintNeverTouchesAgentConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, agent := range []string{"claude", "codex", "cursor-agent"} {
		if _, _, code := printHooks(t, []string{"print", agent}); code != 0 {
			t.Fatalf("%s: exit non-zero", agent)
		}
	}
	for _, rel := range []string{".claude", ".cursor", ".codex"} {
		if _, err := os.Stat(filepath.Join(home, rel)); !os.IsNotExist(err) {
			t.Fatalf("%s was created or read into existence: %v", rel, err)
		}
	}
}

// jsonBlock extracts the single JSON object from the printed output, proving the
// snippet is valid JSON that can be pasted as-is.
func jsonBlock(t *testing.T, out string) map[string]any {
	t.Helper()
	start := strings.Index(out, "{")
	end := strings.LastIndex(out, "}")
	if start < 0 || end <= start {
		t.Fatalf("no JSON object in output:\n%s", out)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(out[start:end+1]), &doc); err != nil {
		t.Fatalf("snippet is not valid JSON: %v\n%s", err, out[start:end+1])
	}
	return doc
}
