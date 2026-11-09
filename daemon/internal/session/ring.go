package session

import "sync"

type RingBuffer struct {
	mu   sync.Mutex
	buf  []byte
	max  int
	w    int
	full bool
}

func NewRingBuffer(max int) *RingBuffer {
	if max <= 0 {
		max = 5 * 1024 * 1024
	}
	return &RingBuffer{buf: make([]byte, max), max: max}
}

func (r *RingBuffer) Write(p []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(p) == 0 {
		return
	}
	if len(p) >= r.max {
		copy(r.buf, p[len(p)-r.max:])
		r.w = 0
		r.full = true
		return
	}
	end := r.w + len(p)
	if end >= r.max {
		r.full = true
	}
	n := copy(r.buf[r.w:], p)
	copy(r.buf, p[n:])
	r.w = end % r.max
}

func (r *RingBuffer) Bytes() []byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.full {
		out := make([]byte, r.w)
		copy(out, r.buf[:r.w])
		return out
	}
	out := make([]byte, r.max)
	n := copy(out, r.buf[r.w:])
	copy(out[n:], r.buf[:r.w])
	return out
}

func (r *RingBuffer) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.full {
		return r.max
	}
	return r.w
}
