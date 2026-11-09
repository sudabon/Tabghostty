package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

// This is the regression the remote heuristic exists for: `ssh` sets an
// integrated session running through OSC, and the remote host has nothing of
// ours to clear it, so the tab used to stay running for the whole login. The
// test drives the real poller — foreground lookup, `ps` name, screen read and
// state override — rather than the classifier alone.
func TestPollFallbackReadsRemotePromptAsIdle(t *testing.T) {
	const shell = "/bin/zsh"
	if _, err := os.Stat(shell); err != nil {
		t.Skipf("%s is not available: %v", shell, err)
	}

	home := t.TempDir()
	t.Setenv("HOME", home)
	// Writes the integration and its zdot inject files under the isolated
	// HOME, which is what makes the session integrated.
	zshIntegrationScript(t)

	// A shell symlinked to `ssh` stands in for the real client: the poller
	// keys off the foreground executable name, and this stand-in paints a
	// remote-looking prompt and then sits still, exactly as a remote login
	// does once its shell is waiting for input.
	fake := filepath.Join(t.TempDir(), "ssh")
	if err := os.Symlink("/bin/sh", fake); err != nil {
		t.Fatalf("symlink stand-in client: %v", err)
	}

	// Cols/Rows are required: Create only opens the VT model with a size, and
	// the heuristic has nothing to read without it.
	s, err := Create(CreateOpts{
		Shell:           shell,
		Cwd:             home,
		Cols:            80,
		Rows:            24,
		RingBufferBytes: 64 * 1024,
	})
	if err != nil {
		t.Fatalf("Create(%s): %v", shell, err)
	}
	t.Cleanup(func() { _ = s.Close() })

	waitForPrompt(t, s)
	if !s.Info().Integrated {
		t.Fatal("session is not integrated, so the override this test covers would go unexercised")
	}

	m := &Manager{sessions: map[string]*Session{s.ID: s}}
	mustWrite(t, s, fake+` -c 'printf "[user@remote ~]$ "; sleep 30'`+"\n")
	waitFor(t, "the integration to report the login as running",
		func(i Info) bool { return i.State == StateRunning }, s)

	// The verdict only means anything once the stand-in owns the foreground
	// and has painted its prompt.
	deadline := time.Now().Add(shellTestTimeout)
	var fgName string
	for {
		running, name := foregroundInfo(s)
		fgName = name
		bottom := lastNonBlankLine(s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive}).Lines)
		// Deliberately not gated on isRemoteClient: the readiness check must
		// not depend on the code under test, or a broken match would time out
		// here instead of failing the assertion below.
		if running && strings.HasPrefix(strings.TrimSpace(bottom), "[user@remote") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stand-in client never reached its prompt; foreground = %q, bottom = %q, session = %+v\noutput:\n%s",
				name, bottom, s.Info(), s.Ring.Bytes())
		}
		time.Sleep(20 * time.Millisecond)
	}

	m.pollFallback()

	info := s.Info()
	if info.State != StateIdle {
		t.Errorf("state = %s, want idle at the remote prompt (foreground = %q)\noutput:\n%s", info.State, fgName, s.Ring.Bytes())
	}
	if !strings.Contains(info.Command, "ssh") {
		t.Errorf("command = %q, want the login command line preserved", info.Command)
	}
}

// The same wiring must keep a remote command running, so the fix does not turn
// every login into a permanently idle tab.
func TestPollFallbackKeepsRemoteCommandRunning(t *testing.T) {
	const shell = "/bin/zsh"
	if _, err := os.Stat(shell); err != nil {
		t.Skipf("%s is not available: %v", shell, err)
	}

	home := t.TempDir()
	t.Setenv("HOME", home)
	zshIntegrationScript(t)

	fake := filepath.Join(t.TempDir(), "ssh")
	if err := os.Symlink("/bin/sh", fake); err != nil {
		t.Fatalf("symlink stand-in client: %v", err)
	}

	s, err := Create(CreateOpts{
		Shell:           shell,
		Cwd:             home,
		Cols:            80,
		Rows:            24,
		RingBufferBytes: 64 * 1024,
	})
	if err != nil {
		t.Fatalf("Create(%s): %v", shell, err)
	}
	t.Cleanup(func() { _ = s.Close() })

	waitForPrompt(t, s)
	m := &Manager{sessions: map[string]*Session{s.ID: s}}

	// Output with no prompt on the bottom line is a command in flight.
	mustWrite(t, s, fake+` -c 'printf "installing packages\n"; sleep 30'`+"\n")
	waitFor(t, "the integration to report the login as running",
		func(i Info) bool { return i.State == StateRunning }, s)

	deadline := time.Now().Add(shellTestTimeout)
	for {
		running, name := foregroundInfo(s)
		bottom := lastNonBlankLine(s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive}).Lines)
		if running && strings.Contains(bottom, "installing packages") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stand-in client never produced output; foreground = %q, bottom = %q\noutput:\n%s", name, bottom, s.Ring.Bytes())
		}
		time.Sleep(20 * time.Millisecond)
	}

	m.pollFallback()

	if got := s.Info().State; got != StateRunning {
		t.Errorf("state = %s, want running while the remote command produces output\noutput:\n%s", got, s.Ring.Bytes())
	}
}
