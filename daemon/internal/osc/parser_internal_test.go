package osc

import (
	"bytes"
	"testing"
)

func TestParserDropsOversizedUnterminatedOSC(t *testing.T) {
	var p Parser
	p.Feed(append([]byte("\x1b]"), bytes.Repeat([]byte{'x'}, 8192)...))

	if len(p.buf) != 0 {
		t.Fatalf("buffer length = %d, want 0", len(p.buf))
	}
}

func TestParserReleasesOversizedBackingBufferWithoutOSC(t *testing.T) {
	var p Parser
	p.Feed(bytes.Repeat([]byte{'x'}, 9000))

	if len(p.buf) != 4096 {
		t.Fatalf("buffer length = %d, want 4096", len(p.buf))
	}
	if cap(p.buf) > 4096 {
		t.Fatalf("buffer capacity = %d, want at most 4096", cap(p.buf))
	}
}
