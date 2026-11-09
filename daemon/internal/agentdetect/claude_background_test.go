package agentdetect

import (
	"testing"
)

func identifyClaude(h *harness) {
	h.engine.OnCommandStart(h.id, "claude")
}

func TestClaudeBackgroundHoldsWorking(t *testing.T) {
	h := newHarness(t, nil)
	identifyClaude(h)
	h.screen.set("✻ Churned for 30m 19s · 2 shells still running", "❯")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateWorking {
		t.Fatalf("state = %s, want working", s.State)
	}
	if s.Signal != SignalScreen {
		t.Fatalf("signal = %s, want screen", s.Signal)
	}
}

func TestClaudeBackgroundLocalAgentHoldsWorking(t *testing.T) {
	h := newHarness(t, nil)
	identifyClaude(h)
	h.screen.set("✻ Churned for 3m 1s · 1 local agent still running", "❯")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateWorking {
		t.Fatalf("state = %s, want working for local-agent variant", s.State)
	}
}

func TestClaudeCompletedTurnWithoutStillRunningIsIdle(t *testing.T) {
	h := newHarness(t, nil)
	identifyClaude(h)
	h.screen.set("✻ Churned for 30m 19s", "❯")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateIdle {
		t.Fatalf("state = %s, want idle", s.State)
	}
}

func TestClaudeBackgroundBlockedOutranks(t *testing.T) {
	h := newHarness(t, nil)
	identifyClaude(h)
	h.screen.set(
		"✻ Churned for 30m 19s · 2 shells still running",
		"Do you want to make this edit?",
		"❯ 1. Yes",
	)
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateBlocked {
		t.Fatalf("state = %s, want blocked", s.State)
	}
}

func TestClaudeBackgroundPatternIsClaudeOnly(t *testing.T) {
	reg := Load(LoadOptions{DisableLocal: true})
	claude, ok := reg.Manifest(IDClaude)
	if !ok {
		t.Fatal("missing claude")
	}
	found := false
	for _, p := range claude.Working {
		if p.ID == "background" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("claude manifest missing background working pattern")
	}
	for _, id := range []string{IDCodex, IDCursor} {
		m, ok := reg.Manifest(id)
		if !ok {
			continue
		}
		for _, p := range m.Working {
			if p.ID == "background" {
				t.Errorf("%s unexpectedly has background working pattern", id)
			}
		}
	}
}

func TestClaudeBackgroundCompletionReturnsIdle(t *testing.T) {
	h := newHarness(t, nil)
	identifyClaude(h)
	h.screen.set("✻ Churned for 30m 19s · 2 shells still running", "❯")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	if mustSnap(t, h.engine, h.id).State != StateWorking {
		t.Fatalf("setup: state = %s, want working", mustSnap(t, h.engine, h.id).State)
	}
	h.screen.set("❯")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateIdle {
		t.Fatalf("state = %s, want idle after background line disappears", s.State)
	}
}
