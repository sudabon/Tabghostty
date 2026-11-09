package notifyarbiter

import (
	"sync"
	"time"
)

// Window is the first-wins agent-attention dedupe interval.
const Window = 4 * time.Second

// Clock supplies monotonic timestamps for the attention window.
type Clock interface {
	Now() time.Time
}

// SystemClock is the production clock.
type SystemClock struct{}

func (SystemClock) Now() time.Time { return time.Now() }

// Arbiter deduplicates agent-attention notifications per session.
type Arbiter struct {
	clock Clock

	mu   sync.Mutex
	last map[string]time.Time
}

func New(clock Clock) *Arbiter {
	if clock == nil {
		clock = SystemClock{}
	}
	return &Arbiter{clock: clock, last: map[string]time.Time{}}
}

// Allow reports whether this session may emit an agent-attention notification.
// The first eligible event wins; later events inside Window are suppressed.
func (a *Arbiter) Allow(sessionID string) bool {
	if a == nil || sessionID == "" {
		return true
	}
	now := a.clock.Now()
	a.mu.Lock()
	defer a.mu.Unlock()
	if prev, ok := a.last[sessionID]; ok && now.Sub(prev) < Window {
		return false
	}
	a.last[sessionID] = now
	return true
}

// Forget drops the dedupe entry for a closed session.
func (a *Arbiter) Forget(sessionID string) {
	if a == nil {
		return
	}
	a.mu.Lock()
	delete(a.last, sessionID)
	a.mu.Unlock()
}
