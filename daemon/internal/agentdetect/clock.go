package agentdetect

import (
	"sync"
	"time"
)

// SystemClock is the production wall/monotonic clock.
type SystemClock struct{}

func (SystemClock) Now() time.Time { return time.Now() }

// SystemScheduler uses time.AfterFunc.
type SystemScheduler struct{}

func (SystemScheduler) AfterFunc(d time.Duration, fn func()) func() {
	t := time.AfterFunc(d, fn)
	return func() { t.Stop() }
}

type scheduled struct {
	id       int
	when     time.Time
	fn       func()
	canceled bool
}

// ManualClock is a deterministic clock and scheduler for tests.
type ManualClock struct {
	mu      sync.Mutex
	now     time.Time
	nextID  int
	pending []scheduled
}

// NewManualClock starts at t. If t is zero, a fixed epoch is used.
func NewManualClock(t time.Time) *ManualClock {
	if t.IsZero() {
		t = time.Unix(1_700_000_000, 0)
	}
	return &ManualClock{now: t}
}

func (c *ManualClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *ManualClock) AfterFunc(d time.Duration, fn func()) func() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextID++
	id := c.nextID
	c.pending = append(c.pending, scheduled{id: id, when: c.now.Add(d), fn: fn})
	return func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		for i := range c.pending {
			if c.pending[i].id == id {
				c.pending[i].canceled = true
				return
			}
		}
	}
}

// Advance moves the clock forward and fires due timers in order.
func (c *ManualClock) Advance(d time.Duration) {
	if d < 0 {
		return
	}
	c.mu.Lock()
	target := c.now.Add(d)
	c.mu.Unlock()
	for {
		fn, ok := c.popDue(target)
		if !ok {
			c.mu.Lock()
			c.now = target
			c.mu.Unlock()
			return
		}
		fn()
	}
}

func (c *ManualClock) popDue(target time.Time) (func(), bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	idx := -1
	for i, s := range c.pending {
		if s.canceled || s.when.After(target) {
			continue
		}
		if idx < 0 || s.when.Before(c.pending[idx].when) || (s.when.Equal(c.pending[idx].when) && s.id < c.pending[idx].id) {
			idx = i
		}
	}
	if idx < 0 {
		return nil, false
	}
	s := c.pending[idx]
	c.pending = append(c.pending[:idx], c.pending[idx+1:]...)
	c.now = s.when
	return s.fn, true
}
