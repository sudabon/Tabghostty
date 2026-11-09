package session

import (
	"bytes"
	"io"
	"log"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/osc"
)

func TestApplyEventDoesNotReviveExitedSession(t *testing.T) {
	s := &Session{State: StateExited}

	s.applyEvent(osc.Event{Kind: osc.EventCmdEnd})

	if s.State != StateExited {
		t.Fatalf("state = %q, want %q", s.State, StateExited)
	}
}

func TestApplyEventNotifyDoesNotChangeRunningState(t *testing.T) {
	s := &Session{State: StateRunning, Cwd: "/tmp", Command: "codex"}

	s.applyEvent(osc.Event{Kind: osc.EventNotify, Title: "Codex", Body: "needs approval"})

	if s.State != StateRunning || s.Cwd != "/tmp" || s.Command != "codex" {
		t.Fatalf("session = %+v, want running unchanged", s)
	}
}

func TestReadLoopLogsNonEOFErrors(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	s := &Session{ID: "session", pty: reader, logger: log.New(&logs, "", 0)}

	s.readLoop()

	if got := logs.String(); !strings.Contains(got, "session session pty read:") {
		t.Fatalf("log = %q, want PTY read error", got)
	}
}

func TestWriteDropsUnsolicitedOSC11Report(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	s := &Session{pty: writer}
	report := []byte("\x1b]11;rgb:ffff/ffff/ffff\x1b\\")
	if err := s.Write(report); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("PTY input = %q, want unsolicited OSC 11 report dropped", got)
	}
}

func TestColorQueryWritesThemeReportToPTY(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	s := &Session{pty: writer, palette: osc.LightPalette()}
	s.handleEvents(s.parser.Feed([]byte("\x1b]11;?\x07")))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	want := "\x1b]11;rgb:ffff/ffff/ffff\x07"
	if string(got) != want {
		t.Fatalf("PTY input = %q, want daemon OSC 11 report %q", got, want)
	}
}

func TestWriteDropsXtermOSC11ReportAfterDaemonReply(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	s := &Session{pty: writer, palette: osc.LightPalette()}
	s.handleEvents(s.parser.Feed([]byte("\x1b]11;?\x07")))
	report := []byte("\x1b]11;rgb:0000/0000/0000\x1b\\")
	if err := s.Write(report); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(got), "rgb:0000/0000/0000") {
		t.Fatalf("PTY input = %q, want xterm OSC 11 report dropped", got)
	}
}

func TestWriteDropsDuplicateOSC11Report(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	s := &Session{pty: writer}
	s.handleEvents(s.parser.Feed([]byte("\x1b]11;?\x07")))
	report := []byte("\x1b]11;rgb:ffff/ffff/ffff\x1b\\")
	if err := s.Write(report); err != nil {
		t.Fatal(err)
	}
	if err := s.Write(report); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(got), "rgb:ffff/ffff/ffff") != 0 {
		t.Fatalf("PTY input = %q, want xterm OSC 11 reports dropped", got)
	}
}

func TestColorQueryDoesNotEmitOnEvent(t *testing.T) {
	called := false
	s := &Session{onEvent: func(*Session, osc.Event) { called = true }}
	s.handleEvents(s.parser.Feed([]byte("\x1b]11;?\x07")))
	if called {
		t.Fatal("color query should not broadcast session state")
	}
}

func TestMergeThemeEnvReplacesColorHints(t *testing.T) {
	got := mergeThemeEnv([]string{"COLORFGBG=15;0", "FOO=bar", "TERM_THEME=dark"}, osc.LightPalette())
	joined := strings.Join(got, ",")
	if !strings.Contains(joined, "FOO=bar") {
		t.Fatalf("env = %#v, want FOO preserved", got)
	}
	if strings.Contains(joined, "COLORFGBG=15;0") || strings.Contains(joined, "TERM_THEME=dark") {
		t.Fatalf("env = %#v, want old color hints removed", got)
	}
	if !strings.Contains(joined, "TERM_THEME=light") || !strings.Contains(joined, "COLORFGBG=0;15") {
		t.Fatalf("env = %#v, want light theme hints", got)
	}
}

func TestCompletedRunDurationIsReported(t *testing.T) {
	tests := []struct {
		name     string
		complete func(*Session)
	}{
		{
			name: "command end",
			complete: func(s *Session) {
				s.applyEvent(osc.Event{Kind: osc.EventCmdEnd})
			},
		},
		{
			name: "prompt",
			complete: func(s *Session) {
				s.applyEvent(osc.Event{Kind: osc.EventPrompt})
			},
		},
		{
			name: "fallback idle",
			complete: func(s *Session) {
				s.SetFallbackState(false, "")
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &Session{State: StateRunning, RunStarted: time.Now().Add(-100 * time.Millisecond)}
			tt.complete(s)

			if got := s.Info().RunMs; got < 50 {
				t.Fatalf("RunMs = %d, want completed duration", got)
			}
		})
	}
}

func TestApplyEventShellExitOnlyRecordsTheExitRoute(t *testing.T) {
	s := &Session{State: StateIdle, Cwd: "/tmp/proj", Command: "bash", PromptSeen: true}
	code := 1

	s.applyEvent(osc.Event{Kind: osc.EventShellExit, ExitCode: &code})

	if !s.ShellExited {
		t.Fatal("ShellExited = false, want true")
	}
	if s.State != StateIdle || s.Cwd != "/tmp/proj" || s.Command != "bash" {
		t.Fatalf("session = %+v, want state/cwd/command unchanged", s)
	}
	if s.ExitCode != nil {
		t.Fatalf("ExitCode = %d, want untouched", *s.ExitCode)
	}
}

// bash's DEBUG trap (and zsh preexec) reports `exit` as a command before the
// process dies. That OSC arrives even when the EXIT/zshexit hook is missing —
// stale integration, a user trap that overwrote ours, or a drain timeout —
// so it must count as a user-requested exit on its own.
func TestApplyEventExitCommandRecordsShellExited(t *testing.T) {
	for _, cmd := range []string{"exit", "exit 1", "logout", "builtin exit"} {
		t.Run(cmd, func(t *testing.T) {
			s := &Session{State: StateIdle, PromptSeen: true}
			s.applyEvent(osc.Event{Kind: osc.EventCmdStart, Command: cmd})
			if !s.ShellExited {
				t.Fatalf("ShellExited = false for %q, want true", cmd)
			}
		})
	}
}

func TestApplyEventOrdinaryCommandDoesNotRecordShellExited(t *testing.T) {
	s := &Session{State: StateIdle, PromptSeen: true}
	s.applyEvent(osc.Event{Kind: osc.EventCmdStart, Command: "false"})
	if s.ShellExited {
		t.Fatal("ShellExited = true for false, want false")
	}
}

func TestApplyEventPromptMarksPromptSeen(t *testing.T) {
	s := &Session{State: StateStarting}

	s.applyEvent(osc.Event{Kind: osc.EventPrompt})

	if !s.PromptSeen {
		t.Fatal("PromptSeen = false, want true after OSC 133;A")
	}
	if s.State != StateIdle {
		t.Fatalf("state = %q, want %q", s.State, StateIdle)
	}
}

// The integration emits OSC 7 while the startup files are still running, so it
// must not be mistaken for reaching an interactive prompt.
func TestApplyEventCWDDoesNotMarkPromptSeen(t *testing.T) {
	s := &Session{State: StateStarting}

	s.applyEvent(osc.Event{Kind: osc.EventCWD, CWD: "/tmp"})

	if s.PromptSeen {
		t.Fatal("PromptSeen = true, want false until OSC 133;A")
	}
	if !s.Integrated {
		t.Fatal("Integrated = false, want true after OSC 7")
	}
}

func TestInfoExposesExitRouteFlags(t *testing.T) {
	s := &Session{State: StateExited, ShellExited: true, PromptSeen: true}

	info := s.Info()

	if !info.ShellExited || !info.PromptSeen {
		t.Fatalf("info = %+v, want both exit-route flags set", info)
	}
}

// The shell-exit signal is the last thing the shell writes, so it usually
// arrives after cmd.Wait() has already reaped the process.
func TestWaitLoopDrainsOutputBeforeOnExit(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	cmd := exec.Command("/bin/sh", "-c", "exit 1")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}

	type snapshot struct {
		shellExited bool
		exitCode    *int
	}
	seen := make(chan snapshot, 1)
	s := &Session{
		ID:         "s1",
		State:      StateIdle,
		PromptSeen: true,
		Ring:       NewRingBuffer(4096),
		pty:        reader,
		cmd:        cmd,
		done:       make(chan struct{}),
		readDone:   make(chan struct{}),
		drainWait:  2 * time.Second,
		onExit: func(sess *Session) {
			info := sess.Info()
			seen <- snapshot{shellExited: info.ShellExited, exitCode: info.ExitCode}
		},
	}
	go s.readLoop()
	go func() {
		time.Sleep(20 * time.Millisecond)
		_, _ = writer.Write([]byte("\x1b]9973;exit;1\x1b\\"))
		_ = writer.Close()
	}()

	s.waitLoop()

	got := <-seen
	if !got.shellExited {
		t.Fatal("ShellExited = false at onExit, want the late signal to be drained")
	}
	if got.exitCode == nil || *got.exitCode != 1 {
		t.Fatalf("ExitCode = %v, want 1", got.exitCode)
	}
}

func TestWaitLoopGivesUpOnDrainAfterTimeout(t *testing.T) {
	// The write end stays open, so readLoop never returns — as happens when a
	// background job still holds the PTY slave.
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	defer reader.Close()

	cmd := exec.Command("/bin/sh", "-c", "exit 0")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}

	exited := make(chan struct{})
	s := &Session{
		ID:        "s1",
		State:     StateIdle,
		Ring:      NewRingBuffer(4096),
		pty:       reader,
		cmd:       cmd,
		done:      make(chan struct{}),
		readDone:  make(chan struct{}),
		drainWait: 30 * time.Millisecond,
		onExit:    func(*Session) { close(exited) },
	}
	go s.readLoop()

	start := time.Now()
	s.waitLoop()
	elapsed := time.Since(start)

	select {
	case <-exited:
	default:
		t.Fatal("onExit was not called")
	}
	if elapsed > 5*time.Second {
		t.Fatalf("waitLoop took %v, want it to give up near the drain bound", elapsed)
	}
	if s.Info().State != StateExited {
		t.Fatalf("state = %q, want %q", s.Info().State, StateExited)
	}
}
