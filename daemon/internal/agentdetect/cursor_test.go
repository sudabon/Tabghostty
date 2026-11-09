package agentdetect

import (
	"testing"
)

func TestCursorUnknownScreenBecomesIdle(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "agent")
	h.screen.set("files written", "3 hunks applied")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	got := mustSnap(t, h.engine, h.id)
	if got.AgentID != IDCursor {
		t.Fatalf("agent = %q", got.AgentID)
	}
	if got.State != StateIdle {
		t.Fatalf("state = %s, want idle", got.State)
	}
	if got.State == StateBlocked {
		t.Fatal("unknown cursor screen must not be blocked")
	}
}

func TestCursorOSC0AndBELDoNotBlock(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "agent")
	h.screen.set("Cursor Agent", "files written")
	h.engine.OnOutput(h.id, 4)
	h.engine.OnOSC(h.id, 0)
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	got := mustSnap(t, h.engine, h.id)
	if got.State == StateBlocked {
		t.Fatalf("OSC 0/BEL produced blocked: %+v", got)
	}
	if got.State != StateIdle {
		t.Fatalf("state = %s, want idle", got.State)
	}
}

func TestCursorHasNoBlockedAuthority(t *testing.T) {
	reg := Load(LoadOptions{DisableLocal: true})
	m, ok := reg.Manifest(IDCursor)
	if !ok {
		t.Fatal("missing cursor-agent")
	}
	if m.OSCAuthoritative {
		t.Fatal("verified OSC-silent build must not set osc_authoritative")
	}
	if len(m.Blocked) != 0 || m.Allows(StateBlocked, AuthorityScreen) {
		t.Fatal("speculative blocked patterns must not be bundled")
	}
	if m.VerifiedAgainst[0] != "2026.08.11-e8db854" {
		t.Fatalf("verified_against = %v", m.VerifiedAgainst)
	}
}

func TestCursorActivityBecomesWorking(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "cursor-agent")
	h.screen.set("Cursor Agent", "generating response")
	h.engine.OnOutput(h.id, 40)
	got := mustSnap(t, h.engine, h.id)
	if got.AgentID != IDCursor || got.State != StateWorking {
		t.Fatalf("got %+v, want cursor-agent working", got)
	}
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	if mustSnap(t, h.engine, h.id).State != StateIdle {
		t.Fatalf("quiet = %s, want idle", mustSnap(t, h.engine, h.id).State)
	}
}
