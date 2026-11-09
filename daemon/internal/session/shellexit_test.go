package session

import (
	"bytes"
	"errors"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/integration"
	"github.com/sudabon/webtabinal/internal/paths"
)

const shellTestTimeout = 20 * time.Second

// startShellSession spawns a real shell through the PTY with an isolated HOME,
// so the shell integration is written and loaded from a temp directory instead
// of the developer's own Application Support.
func startShellSession(t *testing.T, shell string, rc string) (*Session, <-chan struct{}) {
	t.Helper()
	if _, err := os.Stat(shell); err != nil {
		t.Skipf("%s is not available: %v", shell, err)
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	if rc != "" {
		writeUserRC(t, home, shell, rc)
	}

	exited := make(chan struct{})
	s, err := Create(CreateOpts{
		Shell:           shell,
		Cwd:             home,
		RingBufferBytes: 64 * 1024,
		OnExit:          func(*Session) { close(exited) },
	})
	if err != nil {
		t.Fatalf("Create(%s): %v", shell, err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, exited
}

func writeUserRC(t *testing.T, home, shell, body string) {
	t.Helper()
	name := ".zshrc"
	if filepath.Base(shell) == "bash" {
		// The inject rcfile emulates login startup, so .bash_profile is what
		// gets sourced; plain .bashrc is not read.
		name = ".bash_profile"
	}
	if err := os.WriteFile(filepath.Join(home, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// waitFor polls until cond holds, so tests never depend on a fixed sleep.
func waitFor(t *testing.T, what string, cond func(Info) bool, s *Session) {
	t.Helper()
	deadline := time.Now().Add(shellTestTimeout)
	for time.Now().Before(deadline) {
		if cond(s.Info()) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s; session = %+v\noutput:\n%s", what, s.Info(), s.Ring.Bytes())
}

func waitForPrompt(t *testing.T, s *Session) {
	t.Helper()
	waitFor(t, "the first prompt", func(i Info) bool { return i.PromptSeen }, s)
}

func waitForExit(t *testing.T, s *Session, exited <-chan struct{}) {
	t.Helper()
	select {
	case <-exited:
	case <-time.After(shellTestTimeout):
		t.Fatalf("shell did not exit; session = %+v\noutput:\n%s", s.Info(), s.Ring.Bytes())
	}
}

func mustWrite(t *testing.T, s *Session, in string) {
	t.Helper()
	if err := s.Write([]byte(in)); err != nil {
		t.Fatalf("write %q: %v", in, err)
	}
}

// A failing command followed by a user-requested exit is the case the
// exit-status rule got wrong: the shell exits with 1 although the user asked
// for it. Both shells and both exit routes must produce the signal.
func TestRealShellUserExitAfterFailingCommandClosesTab(t *testing.T) {
	for _, shell := range []string{"/bin/bash", "/bin/zsh"} {
		for _, route := range []struct {
			name  string
			input string
		}{
			{"exit builtin", "exit\n"},
			{"end of file", "\x04"},
		} {
			t.Run(filepath.Base(shell)+" "+route.name, func(t *testing.T) {
				s, exited := startShellSession(t, shell, "")
				waitForPrompt(t, s)

				mustWrite(t, s, "false\n")
				waitFor(t, "false to report status 1", func(i Info) bool {
					return i.State == StateIdle && i.ExitCode != nil && *i.ExitCode == 1
				}, s)

				mustWrite(t, s, route.input)
				waitForExit(t, s, exited)

				info := s.Info()
				if !info.ShellExited {
					t.Fatalf("ShellExited = false, want the shell-exit signal\noutput:\n%s", s.Ring.Bytes())
				}
				if info.ExitCode == nil || *info.ExitCode != 1 {
					t.Fatalf("ExitCode = %v, want 1", info.ExitCode)
				}
				if !shouldCloseTab(info, true) {
					t.Fatalf("shouldCloseTab = false for %+v, want the tab closed", info)
				}
			})
		}
	}
}

func TestRealShellUserExitHookStillRuns(t *testing.T) {
	for _, tc := range []struct {
		shell string
		rc    string
	}{
		{"/bin/bash", "trap 'echo USER_EXIT_TRAP_RAN' EXIT\n"},
		{"/bin/zsh", "zshexit() { print USER_ZSHEXIT_RAN }\n"},
	} {
		t.Run(filepath.Base(tc.shell), func(t *testing.T) {
			s, exited := startShellSession(t, tc.shell, tc.rc)
			waitForPrompt(t, s)

			mustWrite(t, s, "exit\n")
			waitForExit(t, s, exited)

			if !s.Info().ShellExited {
				t.Fatalf("ShellExited = false, want the shell-exit signal\noutput:\n%s", s.Ring.Bytes())
			}
			// The drain in waitLoop covers the OSC signal; the user's echo may
			// still be in flight, so poll the ring buffer for it.
			deadline := time.Now().Add(2 * time.Second)
			for time.Now().Before(deadline) {
				if containsRC(s, "_RAN") {
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
			t.Fatalf("user exit hook did not run\noutput:\n%s", s.Ring.Bytes())
		})
	}
}

func containsRC(s *Session, want string) bool {
	return bytes.Contains(s.Ring.Bytes(), []byte(want))
}

// bashIntegrationScript and zshIntegrationScript write the embedded scripts to
// the isolated HOME and return the path the shell should source.
func bashIntegrationScript(t *testing.T) string {
	t.Helper()
	if err := integration.Write(); err != nil {
		t.Fatal(err)
	}
	path, err := paths.BashIntegrationPath()
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func zshIntegrationScript(t *testing.T) string {
	t.Helper()
	if err := integration.Write(); err != nil {
		t.Fatal(err)
	}
	path, err := paths.IntegrationPath()
	if err != nil {
		t.Fatal(err)
	}
	return path
}

// runShell feeds input to a non-PTY interactive shell and returns everything it
// wrote. A pipe is enough here: we only care that no OSC is emitted.
func runShell(t *testing.T, shell, input string) string {
	t.Helper()
	cmd := exec.Command(shell, "-i")
	cmd.Stdin = strings.NewReader(input)
	// Strip WEBTABINAL_* so the test still exercises the guard when it is run
	// from inside a WebTabinal session.
	env := []string{"TERM=dumb"}
	for _, e := range os.Environ() {
		if !strings.HasPrefix(e, "WEBTABINAL_") && !strings.HasPrefix(e, "TERM=") {
			env = append(env, e)
		}
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("run %s: %v\noutput:\n%s", shell, err, out)
		}
	}
	return string(out)
}

// The integration is written to disk for every session, so a shell started
// outside WebTabinal can source it; the session-id guard must keep it silent.
func TestIntegrationScriptEmitsNothingWithoutSessionID(t *testing.T) {
	for _, tc := range []struct {
		shell  string
		script func(*testing.T) string
	}{
		{"/bin/bash", bashIntegrationScript},
		{"/bin/zsh", zshIntegrationScript},
	} {
		t.Run(filepath.Base(tc.shell), func(t *testing.T) {
			if _, err := os.Stat(tc.shell); err != nil {
				t.Skipf("%s is not available: %v", tc.shell, err)
			}
			t.Setenv("HOME", t.TempDir())
			path := tc.script(t)

			out := runShell(t, tc.shell, ". '"+path+"'\nexit 0\n")

			if strings.Contains(out, "9973") {
				t.Fatalf("output contained a private OSC without WEBTABINAL_SESSION_ID: %q", out)
			}
		})
	}
}

// End-to-end through the real Manager: the reported bug was that a tab
// survived `exit` after a command that found nothing, because `exit` returns
// that command's status. All three routes must remove the session.
func TestManagerClosesTabForEveryUserExitRoute(t *testing.T) {
	for _, tc := range []struct {
		name  string
		steps []string
	}{
		{"grep miss then exit", []string{"grep zzzznope /etc/hosts\n", "exit\n"}},
		{"grep miss then ctrl-d", []string{"grep zzzznope /etc/hosts\n", "\x04"}},
		{"clean exit", []string{"true\n", "exit\n"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			store := newManagerConfig(t, `{"close_tab_on_clean_exit":true,"shell":"/bin/bash","auth_token":"test"}`)
			m := NewManager(store, log.New(os.Stderr, "", 0))
			t.Cleanup(m.Close)

			s, err := m.Create(home)
			if err != nil {
				t.Fatal(err)
			}
			waitForPrompt(t, s)
			for _, step := range tc.steps {
				mustWrite(t, s, step)
				time.Sleep(150 * time.Millisecond)
			}

			deadline := time.Now().Add(10 * time.Second)
			for time.Now().Before(deadline) {
				if _, ok := m.Get(s.ID); !ok {
					info := s.Info()
					t.Logf("tab closed: exit=%v shell_exited=%v prompt_seen=%v",
						*info.ExitCode, info.ShellExited, info.PromptSeen)
					return
				}
				time.Sleep(20 * time.Millisecond)
			}
			t.Fatalf("tab was not closed; session = %+v\noutput:\n%s", s.Info(), s.Ring.Bytes())
		})
	}
}
