package notifyarbiter

import (
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/agentdetect"
)

func TestAllowFirstWinsWithinWindow(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	a := New(clock)
	if !a.Allow("s1") {
		t.Fatal("first event should emit")
	}
	clock.Advance(2 * time.Second)
	if a.Allow("s1") {
		t.Fatal("second event within window should suppress")
	}
	if !a.Allow("s2") {
		t.Fatal("other sessions are independent")
	}
	clock.Advance(3 * time.Second)
	if !a.Allow("s1") {
		t.Fatal("event after window should emit")
	}
}

func TestForgetClearsWindow(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	a := New(clock)
	if !a.Allow("s1") {
		t.Fatal("first event should emit")
	}
	a.Forget("s1")
	if !a.Allow("s1") {
		t.Fatal("closed session should not suppress a new session id reuse")
	}
}
