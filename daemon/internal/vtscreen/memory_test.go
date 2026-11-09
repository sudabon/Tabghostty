package vtscreen

import (
	"runtime"
	"strings"
	"testing"
)

func TestPerSessionMemoryAt200x60(t *testing.T) {
	payload := []byte("\x1b[H\x1b[2J" + strings.Repeat("x", 200) + "\x1b[?1049h\x1b[H\x1b[2J" + strings.Repeat("y", 200))
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	s, err := New(200, 60)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Feed(payload); err != nil {
		t.Fatal(err)
	}
	snap := s.Snapshot(SnapshotOptions{Buffer: BufferAlternate, Lines: 60})
	if !snap.Available || snap.Cols != 200 || snap.Rows != 60 {
		t.Fatalf("snapshot = %+v", snap)
	}
	runtime.KeepAlive(s)
	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	used := int64(after.HeapAlloc) - int64(before.HeapAlloc)
	if used < 0 {
		used = int64(after.HeapAlloc)
	}
	t.Logf("200x60 primary+alternate heap delta: %d bytes (review target 1 MiB)", used)
	_ = s.Close()
}
