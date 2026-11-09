package vtscreen

import (
	"bytes"
	"errors"
	"log"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

func TestSplitAltTransitionsKeepsSurroundingBytes(t *testing.T) {
	in := []byte("AB\x1b[?1049hCD\x1b[?1049lE")
	got := splitAltTransitions(in)
	want := [][]byte{
		[]byte("AB"),
		[]byte("\x1b[?1049h"),
		[]byte("CD"),
		[]byte("\x1b[?1049l"),
		[]byte("E"),
	}
	if len(got) != len(want) {
		t.Fatalf("chunks = %d, want %d (%q)", len(got), len(want), got)
	}
	for i := range want {
		if string(got[i]) != string(want[i]) {
			t.Fatalf("chunk[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestAdapterConformance(t *testing.T) {
	runConformance(t, New, nil)
}

func TestFeedTerminalQueriesDoNotBlock(t *testing.T) {
	s, err := New(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })

	// TUI apps (claude, cursor-agent) send DA1/DSR on startup. x/vt writes
	// replies to an io.Pipe; without a reader Feed would block forever.
	queries := []byte("\x1b[c\x1b[>c\x1b[6n\x1b[?6n")
	done := make(chan error, 1)
	go func() {
		done <- s.Feed(queries)
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Feed queries: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Feed blocked on terminal query replies")
	}
}

func TestAdapterContractGeometryAndLifecycle(t *testing.T) {
	s, err := New(120, 40)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 15})
	if !snap.Available || snap.Cols != 120 || snap.Rows != 40 {
		t.Fatalf("snapshot = %+v, want 120x40 available", snap)
	}
	if len(snap.Lines) != 15 {
		t.Fatalf("lines = %d, want 15", len(snap.Lines))
	}

	in := []byte("ok")
	if err := s.Feed(in); err != nil {
		t.Fatal(err)
	}
	in[0] = 'Z'
	again := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 40})
	if !strings.HasPrefix(again.Lines[0], "ok") {
		t.Fatalf("line = %q after mutating input", again.Lines[0])
	}

	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.Feed([]byte("x")); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("Feed after close = %v", err)
	}
	if s.Snapshot(SnapshotOptions{Lines: 1}).Available {
		t.Fatal("snapshot available after close")
	}
}

func TestFeedFailureIsUnavailableWithoutLoggingContents(t *testing.T) {
	if ModelName != "charmbracelet" { // Tabghostty: charmbracelet adapter internals; see daemon/UPSTREAM.md
		t.Skip("tests the charmbracelet adapter, which the ghostty build does not use")
	}
	s, err := Open(Options{Cols: 8, Rows: 2})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	es := s.(*emulatorScreen)
	var logs bytes.Buffer
	es.logger = log.New(&logs, "", 0)
	es.failLogInterval = time.Hour
	es.write = func([]byte) error { return errors.New("boom") }

	payload := []byte("SECRET-SCREEN")
	if err := s.Feed(payload); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("err = %v, want ErrUnavailable", err)
	}
	if s.Snapshot(SnapshotOptions{Lines: 2}).Available {
		t.Fatal("model still available after feed failure")
	}
	got := logs.String()
	if !strings.Contains(got, "model unavailable") || !strings.Contains(got, "feed") {
		t.Fatalf("log = %q, want metadata-only failure", got)
	}
	if strings.Contains(got, "SECRET-SCREEN") {
		t.Fatalf("log leaked screen contents: %q", got)
	}
}

func TestFailureLoggingIsRateLimited(t *testing.T) {
	if ModelName != "charmbracelet" { // Tabghostty: charmbracelet adapter internals; see daemon/UPSTREAM.md
		t.Skip("tests the charmbracelet adapter, which the ghostty build does not use")
	}
	s, err := Open(Options{Cols: 4, Rows: 2})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	es := s.(*emulatorScreen)
	var logs bytes.Buffer
	es.logger = log.New(&logs, "", 0)
	es.failLogInterval = time.Hour
	es.write = func([]byte) error { return errors.New("boom") }

	_ = s.Feed([]byte("a"))
	es.available = true
	_ = s.Feed([]byte("b"))
	if strings.Count(logs.String(), "model unavailable") != 1 {
		t.Fatalf("log count = %q, want 1 rate-limited entry", logs.String())
	}
}

func TestConcurrentFeedResizeSnapshot(t *testing.T) {
	s, err := New(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })

	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 50 {
				_ = s.Feed([]byte("abc\n\x1b[H"))
				_ = s.Resize(80, 24)
				snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 10})
				if snap.Available && snap.Lines != nil {
					snap.Lines[0] = "mut"
				}
			}
		}()
	}
	wg.Wait()
}

func FuzzFeed(f *testing.F) {
	f.Add([]byte("hello"))
	f.Add([]byte("\x1b[H\x1b[2J"))
	f.Add([]byte("\x1b[?1049hALT\x1b[?1049l"))
	f.Add([]byte("日本語"))
	f.Add([]byte("e\u0301"))
	f.Fuzz(func(t *testing.T, data []byte) {
		s, err := New(20, 8)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
		_ = s.Feed(data)
		if !utf8.Valid(data) {
			_ = s.Feed(data[:min(len(data), 3)])
		}
		_ = s.Resize(40, 10)
		_ = s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 8})
		_ = s.Snapshot(SnapshotOptions{Buffer: BufferPrimary, Lines: 8})
		_ = s.Snapshot(SnapshotOptions{Buffer: BufferAlternate, Lines: 8})
		_ = s.Close()
		_ = s.Feed([]byte("x"))
	})
}
