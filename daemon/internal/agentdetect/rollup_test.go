package agentdetect

import "testing"

func TestRollupPriority(t *testing.T) {
	if got := Rollup([]State{StateIdle, StateWorking, StateBlocked}); got != StateBlocked {
		t.Fatalf("got %s, want blocked", got)
	}
	if got := Rollup([]State{StateIdle, StateWorking}); got != StateWorking {
		t.Fatalf("got %s, want working", got)
	}
	if got := Rollup([]State{StateNone, StateIdle}); got != StateIdle {
		t.Fatalf("got %s, want idle", got)
	}
}

func TestRollupEmptyIsNone(t *testing.T) {
	if got := Rollup(nil); got != StateNone {
		t.Fatalf("got %s, want none", got)
	}
	if got := Rollup([]State{}); got != StateNone {
		t.Fatalf("got %s, want none", got)
	}
}
