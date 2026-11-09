package vtscreen

import (
	"bytes"
	"errors"
	"testing"
)

func TestFactoryReportsInitialGeometry(t *testing.T) {
	s, err := newFake(120, 40)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 40})
	if !snap.Available {
		t.Fatal("snapshot unavailable")
	}
	if snap.Cols != 120 || snap.Rows != 40 {
		t.Fatalf("geometry = %dx%d, want 120x40", snap.Cols, snap.Rows)
	}
	if len(snap.Lines) != 40 {
		t.Fatalf("lines = %d, want 40", len(snap.Lines))
	}
}

func TestFactoryRejectsInvalidGeometry(t *testing.T) {
	if _, err := newFake(0, 24); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("err = %v, want ErrUnavailable", err)
	}
}

func TestSnapshotDoesNotExposeMutableRows(t *testing.T) {
	s, err := newFake(8, 3)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte("hello")); err != nil {
		t.Fatal(err)
	}

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferPrimary, Lines: 3})
	if len(snap.Lines) == 0 {
		t.Fatal("expected lines")
	}
	snap.Lines[0] = "mutated"
	if len(snap.Lines) > 1 {
		snap.Lines[1] = "also"
	}

	again := s.Snapshot(SnapshotOptions{Buffer: BufferPrimary, Lines: 3})
	if again.Lines[0] == "mutated" {
		t.Fatal("snapshot exposed mutable emulator rows")
	}
	if again.Lines[0] != "hello" {
		t.Fatalf("line = %q, want %q", again.Lines[0], "hello")
	}
}

func TestFeedDoesNotRetainOrMutateInput(t *testing.T) {
	s, err := newFake(8, 2)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	in := []byte("ab")
	if err := s.Feed(in); err != nil {
		t.Fatal(err)
	}
	in[0] = 'Z'
	if !bytes.Equal(in, []byte("Zb")) {
		t.Fatalf("input = %q, want caller-owned mutation to stick", in)
	}

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 2})
	if snap.Lines[0] != "ab" {
		t.Fatalf("line = %q, want %q after mutating input", snap.Lines[0], "ab")
	}
}

func TestCloseMakesModelUnavailable(t *testing.T) {
	s, err := newFake(4, 2)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.Feed([]byte("x")); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("Feed err = %v, want ErrUnavailable", err)
	}
	if err := s.Resize(8, 4); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("Resize err = %v, want ErrUnavailable", err)
	}
	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 2})
	if snap.Available {
		t.Fatal("snapshot still available after Close")
	}
}

func TestBottomLinesPreserveBlankRows(t *testing.T) {
	s, err := newFake(8, 4)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte("top\n\nmid")); err != nil {
		t.Fatal(err)
	}

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 4})
	want := []string{"top", "", "mid", ""}
	if len(snap.Lines) != 4 {
		t.Fatalf("lines = %#v, want 4 rows", snap.Lines)
	}
	for i, line := range want {
		if snap.Lines[i] != line {
			t.Fatalf("line[%d] = %q, want %q", i, snap.Lines[i], line)
		}
	}
}

func TestRequestedLinesExceedHeight(t *testing.T) {
	s, err := newFake(8, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 200})
	if len(snap.Lines) != 24 {
		t.Fatalf("lines = %d, want 24", len(snap.Lines))
	}
}

func TestActiveBottomLinesAreInDisplayOrder(t *testing.T) {
	s, err := newFake(8, 6)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte("a\nb\nc\nd\ne\nf")); err != nil {
		t.Fatal(err)
	}

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 3})
	want := []string{"d", "e", "f"}
	if len(snap.Lines) != 3 {
		t.Fatalf("lines = %#v", snap.Lines)
	}
	for i, line := range want {
		if snap.Lines[i] != line {
			t.Fatalf("line[%d] = %q, want %q", i, snap.Lines[i], line)
		}
	}
}

func TestInactiveBufferCanBeInspected(t *testing.T) {
	s, err := newFake(16, 3)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte("PRIMARY\x1b[?1049hALT")); err != nil {
		t.Fatal(err)
	}

	active := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 3})
	if active.Active != BufferAlternate || active.Lines[0] != "ALT" {
		t.Fatalf("active = %+v, want alternate ALT", active)
	}
	primary := s.Snapshot(SnapshotOptions{Buffer: BufferPrimary, Lines: 3})
	if primary.Buffer != BufferPrimary || primary.Lines[0] != "PRIMARY" {
		t.Fatalf("primary = %+v, want preserved PRIMARY", primary)
	}
	if primary.Active != BufferAlternate {
		t.Fatalf("active buffer changed to %s", primary.Active)
	}
}

func TestTrailingBlankCellsAreTrimmed(t *testing.T) {
	s, err := newFake(10, 1)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte("hi")); err != nil {
		t.Fatal(err)
	}

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 1})
	if snap.Lines[0] != "hi" {
		t.Fatalf("line = %q, want trimmed %q", snap.Lines[0], "hi")
	}
}

func TestResizeUpdatesGeometry(t *testing.T) {
	s, err := newFake(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Resize(160, 50); err != nil {
		t.Fatal(err)
	}

	snap := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 50})
	if snap.Cols != 160 || snap.Rows != 50 {
		t.Fatalf("geometry = %dx%d, want 160x50", snap.Cols, snap.Rows)
	}
	if len(snap.Lines) != 50 {
		t.Fatalf("lines = %d, want 50", len(snap.Lines))
	}
}
