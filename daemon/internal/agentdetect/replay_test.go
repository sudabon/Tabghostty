package agentdetect

import (
	"strings"
	"testing"
)

func TestGenericReplayTimeline(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Executable: "htop", UsingAlt: true})
	h.screen.set("CPU 12%", "Load 0.4")
	h.engine.OnOutput(h.id, 40)
	if mustSnap(t, h.engine, h.id).State != StateWorking {
		t.Fatalf("generic activity = %s", mustSnap(t, h.engine, h.id).State)
	}
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	got := mustSnap(t, h.engine, h.id)
	if got.AgentID != IDGeneric || got.State != StateIdle {
		t.Fatalf("generic quiet = %+v", got)
	}
	if got.State == StateBlocked {
		t.Fatal("generic blocked")
	}
}

func TestFakeClockReplayIsDeterministic(t *testing.T) {
	run := func() []string {
		h := newHarness(t, nil)
		h.engine.OnCommandStart(h.id, "claude")
		h.screen.set("esc to interrupt")
		h.engine.OnOutput(h.id, 40)
		flushDebounce(h)
		h.screen.set("Do you want to")
		h.engine.OnOutput(h.id, 4)
		flushDebounce(h)
		h.screen.set("❯")
		h.clock.Advance(DefaultQuiescence)
		flushDebounce(h)
		var out []string
		s := mustSnap(t, h.engine, h.id)
		out = append(out, s.AgentID, string(s.State), string(s.Signal))
		return out
	}
	a, b := run(), run()
	if strings.Join(a, "/") != strings.Join(b, "/") {
		t.Fatalf("nondeterministic %v vs %v", a, b)
	}
}
