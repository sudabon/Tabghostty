package session

import (
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/osc"
)

func envValue(env []string, key string) (string, bool) {
	prefix := key + "="
	for i := len(env) - 1; i >= 0; i-- {
		if strings.HasPrefix(env[i], prefix) {
			return strings.TrimPrefix(env[i], prefix), true
		}
	}
	return "", false
}

// A terminal emulator whose shell integration exports PROMPT_COMMAND would
// otherwise hand WebTabinal sessions a hook whose defining function is never
// sourced, producing `command not found` on every prompt.
func TestShellEnvDropsInheritedPromptCommand(t *testing.T) {
	t.Setenv("PROMPT_COMMAND", "_cmux_prompt_command")

	env := shellEnv("session-id", osc.PaletteFor("dark"))

	if got, ok := envValue(env, "PROMPT_COMMAND"); ok {
		t.Fatalf("PROMPT_COMMAND = %q, want it dropped", got)
	}
}

func TestShellEnvPreservesUnrelatedEnvironment(t *testing.T) {
	t.Setenv("PROMPT_COMMAND", "_cmux_prompt_command")
	t.Setenv("WEBTABINAL_SHELLENV_PROBE", "keep-me")
	t.Setenv("PATH", "/usr/bin:/bin")

	env := shellEnv("session-id", osc.PaletteFor("dark"))

	if got, ok := envValue(env, "WEBTABINAL_SHELLENV_PROBE"); !ok || got != "keep-me" {
		t.Fatalf("unrelated variable = %q (present=%v), want %q", got, ok, "keep-me")
	}
	if got, ok := envValue(env, "PATH"); !ok || got != "/usr/bin:/bin" {
		t.Fatalf("PATH = %q (present=%v), want it preserved", got, ok)
	}
	if got, ok := envValue(env, "WEBTABINAL_SESSION_ID"); !ok || got != "session-id" {
		t.Fatalf("WEBTABINAL_SESSION_ID = %q (present=%v), want %q", got, ok, "session-id")
	}
	if got, ok := envValue(env, "TERM"); !ok || got != "xterm-256color" {
		t.Fatalf("TERM = %q (present=%v), want xterm-256color", got, ok)
	}
}

// Theme and locale handling must keep working alongside the new filter.
func TestShellEnvStillAppliesThemeAndLocale(t *testing.T) {
	t.Setenv("PROMPT_COMMAND", "_cmux_prompt_command")
	t.Setenv("TERM_THEME", "stale")

	env := shellEnv("session-id", osc.PaletteFor("dark"))

	if got, ok := envValue(env, "TERM_THEME"); !ok || got == "stale" {
		t.Fatalf("TERM_THEME = %q (present=%v), want the palette value", got, ok)
	}
	if _, ok := envValue(env, "LANG"); !ok {
		t.Fatal("LANG should be set from the detected locale")
	}
}
