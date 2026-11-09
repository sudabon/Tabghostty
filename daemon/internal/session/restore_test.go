package session

import (
	"io"
	"os"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/osc"
)

// ptySink gives a Session a writable PTY whose contents the test can read.
func ptySink(t *testing.T) (*Session, func() string) {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reader.Close() })
	s := &Session{ID: "s1", State: StateStarting, pty: writer}
	read := func() string {
		if err := writer.Close(); err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(reader)
		if err != nil {
			t.Fatal(err)
		}
		return string(got)
	}
	return s, read
}

func TestSendWhenReadyWaitsForThePrompt(t *testing.T) {
	s, read := ptySink(t)

	done := make(chan struct{})
	go func() {
		defer close(done)
		sendWhenReady(s, "claude --continue\n", time.Millisecond, 5*time.Second, nil)
	}()

	// Nothing may be written while the shell is still starting.
	time.Sleep(20 * time.Millisecond)
	select {
	case <-done:
		t.Fatal("resume command was written before the prompt")
	default:
	}

	s.applyEvent(osc133A())
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("resume command was not written after the prompt")
	}

	if got := read(); got != "claude --continue\n" {
		t.Fatalf("PTY input = %q, want the resume command", got)
	}
}

func TestSendWhenReadyFallsBackWithoutIntegration(t *testing.T) {
	s, read := ptySink(t)

	start := time.Now()
	// PromptSeen never becomes true, as in a shell with no integration.
	sendWhenReady(s, "codex resume --last\n", time.Millisecond, 60*time.Millisecond, nil)
	elapsed := time.Since(start)

	if elapsed < 60*time.Millisecond {
		t.Fatalf("returned after %v, want it to wait out the fallback", elapsed)
	}
	if got := read(); got != "codex resume --last\n" {
		t.Fatalf("PTY input = %q, want the command sent after the fallback", got)
	}
}

func TestSendWhenReadyWritesOnlyOnce(t *testing.T) {
	s, read := ptySink(t)
	s.applyEvent(osc133A())

	sendWhenReady(s, "claude --continue\n", time.Millisecond, time.Second, nil)
	// A further prompt after the command was sent must not produce a second one.
	s.applyEvent(osc133A())
	time.Sleep(20 * time.Millisecond)

	if got := read(); got != "claude --continue\n" {
		t.Fatalf("PTY input = %q, want exactly one resume command", got)
	}
}

func TestSendWhenReadySkipsAnExitedSession(t *testing.T) {
	s, read := ptySink(t)
	s.mu.Lock()
	s.State = StateExited
	s.mu.Unlock()

	sendWhenReady(s, "claude --continue\n", time.Millisecond, time.Second, nil)

	if got := read(); got != "" {
		t.Fatalf("PTY input = %q, want nothing written to an exited session", got)
	}
}

func TestSendWhenReadyStopsWhenTheSessionExitsWhileWaiting(t *testing.T) {
	s, read := ptySink(t)

	done := make(chan struct{})
	go func() {
		defer close(done)
		sendWhenReady(s, "claude --continue\n", time.Millisecond, 5*time.Second, nil)
	}()
	time.Sleep(10 * time.Millisecond)
	s.mu.Lock()
	s.State = StateExited
	s.mu.Unlock()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("sendWhenReady kept waiting after the session exited")
	}
	if got := read(); got != "" {
		t.Fatalf("PTY input = %q, want nothing after the session exited", got)
	}
}

func TestSendWhenReadyStagedCommandHasNoNewline(t *testing.T) {
	s, read := ptySink(t)
	s.applyEvent(osc133A())

	sendWhenReady(s, "claude --continue", time.Millisecond, time.Second, nil)

	if got := read(); got != "claude --continue" {
		t.Fatalf("PTY input = %q, want the command staged without a newline", got)
	}
}

func TestSendWhenReadyIgnoresEmptyInput(t *testing.T) {
	m := &Manager{}
	s, read := ptySink(t)

	m.SendWhenReady(s, "")
	m.SendWhenReady(nil, "claude --continue\n")
	time.Sleep(20 * time.Millisecond)

	if got := read(); got != "" {
		t.Fatalf("PTY input = %q, want nothing written", got)
	}
}

func osc133A() osc.Event {
	return osc.Event{Kind: osc.EventPrompt}
}
