//go:build ghostty

// Tabghostty: tests for the libghostty-vt screen model (ghostty.go). Not part of upstream webtabinal.
// The normalization cases mirror Tabghostty's Tests/TerminalCoreTests/ScreenNormalizerTests.swift.

package vtscreen

import (
	"reflect"
	"testing"
)

func feedAndSnapshot(t *testing.T, cols, rows int, data string, buffer BufferKind) Snapshot {
	t.Helper()
	s, err := Open(Options{Cols: cols, Rows: rows})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte(data)); err != nil {
		t.Fatal(err)
	}
	return s.Snapshot(SnapshotOptions{Buffer: buffer, Lines: rows})
}

func TestGhosttyModelIdentity(t *testing.T) {
	if ModelName != "ghostty" {
		t.Fatalf("ModelName = %q", ModelName)
	}
	if LibraryVersion() == "" {
		t.Fatal("LibraryVersion is empty")
	}
}

func TestGhosttyNormalizesWideCombiningAndTrailingSpaces(t *testing.T) {
	cases := []struct {
		name       string
		cols, rows int
		data       string
		want       []string
	}{
		{"japanese and trailing spaces", 20, 2, "日本語 abc   \r\n  末尾  ", []string{"日本語 abc", "  末尾"}},
		{"wide char wrapped at last column", 5, 2, "abcd日", []string{"abcd", "日"}},
		{"combining marks stay with base", 10, 2, "éx\r\nがき", []string{"éx", "がき"}},
		{"visible rows only", 20, 3, "one\r\ntwo\r\nthree\r\nfour\r\nfive", []string{"three", "four", "five"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := feedAndSnapshot(t, tc.cols, tc.rows, tc.data, BufferActive)
			if !got.Available || !reflect.DeepEqual(got.Lines, tc.want) {
				t.Fatalf("lines = %#v, want %#v", got.Lines, tc.want)
			}
		})
	}
}

func TestGhosttyKeepsPrimaryWhileAlternateIsActive(t *testing.T) {
	s, err := Open(Options{Cols: 10, Rows: 2})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Feed([]byte("primary\x1b[?1049h\x1b[Halt")); err != nil {
		t.Fatal(err)
	}
	active := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 2})
	if active.Active != BufferAlternate || !reflect.DeepEqual(active.Lines, []string{"alt", ""}) {
		t.Fatalf("active = %+v", active)
	}
	primary := s.Snapshot(SnapshotOptions{Buffer: BufferPrimary, Lines: 2})
	if !reflect.DeepEqual(primary.Lines, []string{"primary", ""}) {
		t.Fatalf("primary = %#v", primary.Lines)
	}
	if err := s.Feed([]byte("\x1b[?1049l")); err != nil {
		t.Fatal(err)
	}
	back := s.Snapshot(SnapshotOptions{Buffer: BufferActive, Lines: 2})
	if back.Active != BufferPrimary || !reflect.DeepEqual(back.Lines, []string{"primary", ""}) {
		t.Fatalf("after leaving alternate = %+v", back)
	}
	alternate := s.Snapshot(SnapshotOptions{Buffer: BufferAlternate, Lines: 2})
	if !reflect.DeepEqual(alternate.Lines, []string{"alt", ""}) {
		t.Fatalf("alternate kept = %#v", alternate.Lines)
	}
}
