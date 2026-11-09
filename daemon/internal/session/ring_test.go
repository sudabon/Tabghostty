package session

import (
	"bytes"
	"testing"
)

func TestRingBufferWrapsInByteOrder(t *testing.T) {
	r := NewRingBuffer(5)
	r.Write([]byte("abc"))
	r.Write([]byte("def"))

	if got := r.Bytes(); !bytes.Equal(got, []byte("bcdef")) {
		t.Fatalf("Bytes() = %q, want %q", got, "bcdef")
	}
	if got := r.Len(); got != 5 {
		t.Fatalf("Len() = %d, want 5", got)
	}
}

func TestRingBufferDoesNotAllocateAfterFilling(t *testing.T) {
	r := NewRingBuffer(1024)
	r.Write(make([]byte, 1024))
	p := make([]byte, 32)

	allocs := testing.AllocsPerRun(100, func() {
		r.Write(p)
	})
	if allocs != 0 {
		t.Fatalf("allocations per full-buffer write = %v, want 0", allocs)
	}
}
