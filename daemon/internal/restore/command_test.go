package restore

import (
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/config"
)

func TestResolveCommandUsesBuiltins(t *testing.T) {
	for agent, want := range map[string]string{
		"claude":       "claude --continue",
		"codex":        "codex resume --last",
		"cursor-agent": "cursor-agent resume",
	} {
		t.Run(agent, func(t *testing.T) {
			got := ResolveCommand(agent, nil)
			if !got.OK {
				t.Fatalf("not resolved: %s", got.Reason)
			}
			if got.Command != want {
				t.Fatalf("command = %q, want %q", got.Command, want)
			}
		})
	}
}

func TestResolveCommandOverrideWins(t *testing.T) {
	got := ResolveCommand("claude", map[string]string{"claude": "claude --resume"})

	if !got.OK || got.Command != "claude --resume" {
		t.Fatalf("resolution = %+v, want the configured override", got)
	}
}

func TestResolveCommandOverrideCanAddAnUnknownAgent(t *testing.T) {
	got := ResolveCommand("mycli", map[string]string{"mycli": "mycli --resume"})

	if !got.OK || got.Command != "mycli --resume" {
		t.Fatalf("resolution = %+v, want the configured command for an agent with no built-in", got)
	}
}

func TestResolveCommandEmptyOverrideDisablesTheAgent(t *testing.T) {
	got := ResolveCommand("cursor-agent", map[string]string{"cursor-agent": ""})

	if got.OK {
		t.Fatalf("resolution = %+v, want the agent disabled", got)
	}
	if !strings.Contains(got.Reason, "disabled") {
		t.Fatalf("reason = %q, want it to say the command is disabled", got.Reason)
	}
}

func TestResolveCommandWhitespaceOverrideDisablesTheAgent(t *testing.T) {
	got := ResolveCommand("claude", map[string]string{"claude": "   "})

	if got.OK {
		t.Fatalf("resolution = %+v, want a whitespace-only command treated as disabled", got)
	}
}

func TestResolveCommandUnmappedAgentIsNotRestorable(t *testing.T) {
	for _, agent := range []string{"generic", "unknown-thing"} {
		t.Run(agent, func(t *testing.T) {
			got := ResolveCommand(agent, nil)
			if got.OK {
				t.Fatalf("resolution = %+v, want no resume command", got)
			}
			if !strings.Contains(got.Reason, "no resume command") {
				t.Fatalf("reason = %q, want it to say there is no command", got.Reason)
			}
		})
	}
}

func TestResolveCommandEmptyAgentIsNotRestorable(t *testing.T) {
	got := ResolveCommand("", nil)

	if got.OK {
		t.Fatalf("resolution = %+v, want no command for a session with no agent", got)
	}
	if !strings.Contains(got.Reason, "no detected agent") {
		t.Fatalf("reason = %q, want it to say there is no agent", got.Reason)
	}
}

func TestResolveCommandRejectsUnusableCommands(t *testing.T) {
	for _, tc := range []struct {
		name    string
		command string
		reason  string
	}{
		{"line feed", "claude --continue\nrm -rf /", "line break"},
		{"carriage return", "claude\r", "line break"},
		{"too long", strings.Repeat("a", config.MaxResumeCommandLen+1), "exceeds"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveCommand("claude", map[string]string{"claude": tc.command})

			if got.OK {
				t.Fatalf("resolution = %+v, want the command rejected", got)
			}
			if !strings.Contains(got.Reason, tc.reason) {
				t.Fatalf("reason = %q, want it to mention %q", got.Reason, tc.reason)
			}
		})
	}
}

func TestResolveCommandAcceptsExactlyTheLengthLimit(t *testing.T) {
	command := strings.Repeat("a", config.MaxResumeCommandLen)

	got := ResolveCommand("claude", map[string]string{"claude": command})

	if !got.OK {
		t.Fatalf("resolution = %+v, want a command at the limit accepted", got)
	}
}

func TestBuiltinCommandsCopyIsIndependent(t *testing.T) {
	BuiltinCommands()["claude"] = "tampered"

	if got := ResolveCommand("claude", nil); got.Command != "claude --continue" {
		t.Fatalf("command = %q, want the built-in table unchanged", got.Command)
	}
}

func TestRestorableMatchesResolution(t *testing.T) {
	if !Restorable("codex", nil) {
		t.Fatal("codex should be restorable")
	}
	if Restorable("generic", nil) {
		t.Fatal("generic should not be restorable")
	}
	if Restorable("codex", map[string]string{"codex": ""}) {
		t.Fatal("a disabled agent should not be restorable")
	}
}
