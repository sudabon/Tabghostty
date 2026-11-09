package session

import (
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestCWDUpdatesOnCdWithoutZshrcSnippet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("ZDOTDIR", home)

	start := t.TempDir()
	dest := t.TempDir()

	s, err := Create(CreateOpts{
		Shell:           "/bin/zsh",
		Cwd:             start,
		RingBufferBytes: 64 * 1024,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if !waitForSession(s, 8*time.Second, func(info Info) bool { return info.Integrated }) {
		t.Fatalf("shell integration did not load; cwd stays %q", s.Info().Cwd)
	}
	if err := s.Write([]byte("cd " + strconv.Quote(dest) + "\n")); err != nil {
		t.Fatal(err)
	}
	if !waitForSession(s, 8*time.Second, func(info Info) bool { return samePath(info.Cwd, dest) }) {
		t.Fatalf("cwd = %q, want %q", s.Info().Cwd, dest)
	}
}

func TestCommandUpdatesOnRunWithoutZshrcSnippet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("ZDOTDIR", home)

	s, err := Create(CreateOpts{
		Shell:           "/bin/zsh",
		Cwd:             t.TempDir(),
		RingBufferBytes: 64 * 1024,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if !waitForSession(s, 8*time.Second, func(info Info) bool { return info.Integrated }) {
		t.Fatal("shell integration did not load")
	}
	const want = "echo webtabinal-cmd-probe"
	if err := s.Write([]byte(want + "\n")); err != nil {
		t.Fatal(err)
	}
	if !waitForSession(s, 8*time.Second, func(info Info) bool { return info.Command == want }) {
		t.Fatalf("command = %q, want %q", s.Info().Command, want)
	}
}

func TestCWDUpdatesOnCdWithoutBashrcSnippet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	start := t.TempDir()
	dest := t.TempDir()

	s, err := Create(CreateOpts{
		Shell:           "/bin/bash",
		Cwd:             start,
		RingBufferBytes: 64 * 1024,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if !waitForSession(s, 8*time.Second, func(info Info) bool { return info.Integrated }) {
		t.Fatalf("shell integration did not load; cwd stays %q; output %q", s.Info().Cwd, string(s.Ring.Bytes()))
	}
	if err := s.Write([]byte("cd " + strconv.Quote(dest) + "\n")); err != nil {
		t.Fatal(err)
	}
	if !waitForSession(s, 8*time.Second, func(info Info) bool { return samePath(info.Cwd, dest) }) {
		t.Fatalf("cwd = %q, want %q", s.Info().Cwd, dest)
	}
}

func TestCommandUpdatesOnRunWithoutBashrcSnippet(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	s, err := Create(CreateOpts{
		Shell:           "/bin/bash",
		Cwd:             t.TempDir(),
		RingBufferBytes: 64 * 1024,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if !waitForSession(s, 8*time.Second, func(info Info) bool { return info.Integrated }) {
		t.Fatalf("shell integration did not load; output %q", string(s.Ring.Bytes()))
	}
	const want = "echo webtabinal-cmd-probe"
	if err := s.Write([]byte(want + "\n")); err != nil {
		t.Fatal(err)
	}
	if !waitForSession(s, 8*time.Second, func(info Info) bool { return info.Command == want }) {
		t.Fatalf("command = %q, want %q", s.Info().Command, want)
	}
}

func waitForSession(s *Session, timeout time.Duration, ok func(Info) bool) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ok(s.Info()) {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return ok(s.Info())
}

func samePath(a, b string) bool {
	if a == b {
		return true
	}
	aa, err1 := filepath.EvalSymlinks(a)
	bb, err2 := filepath.EvalSymlinks(b)
	return err1 == nil && err2 == nil && aa == bb
}
