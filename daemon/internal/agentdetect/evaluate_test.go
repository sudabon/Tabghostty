package agentdetect

import (
	"strings"
	"sync"
	"testing"
	"testing/quick"
	"time"
)

func identifyCodex(h *harness) {
	h.engine.OnCommandStart(h.id, "codex")
}

func TestImmediateBlocked(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("Allow this command to run?")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateBlocked {
		t.Fatalf("state = %s, want blocked", s.State)
	}
	if s.Signal != SignalScreen {
		t.Fatalf("signal = %s", s.Signal)
	}
	if strings.Contains(s.Detail, "Allow this") {
		t.Fatalf("detail leaked screen text: %q", s.Detail)
	}
}

func TestBlockedClearsWhenEvidenceGone(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("Allow this command")
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	if mustSnap(t, h.engine, h.id).State != StateBlocked {
		t.Fatal("setup: want blocked")
	}
	h.screen.set("esc to interrupt")
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	if mustSnap(t, h.engine, h.id).State != StateWorking {
		t.Fatalf("state = %s, want working after blocked cleared", mustSnap(t, h.engine, h.id).State)
	}
}

func TestActivitySupportsWorking(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("unmatched screen")
	h.engine.OnOutput(h.id, 40)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateWorking {
		t.Fatalf("state = %s, want working from activity", s.State)
	}
}

func TestStreamingPauseKeepsWorking(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("unmatched")
	h.engine.OnOutput(h.id, 40)
	h.clock.Advance(500 * time.Millisecond)
	h.screen.set("›")
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateWorking {
		t.Fatalf("state = %s, want working during pause before quiescence", s.State)
	}
}

func TestQuietIdlePromptBecomesIdle(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.engine.OnOutput(h.id, 40)
	h.screen.set("  ›  ")
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateIdle {
		t.Fatalf("state = %s, want idle", s.State)
	}
}

func TestOSCAcceleratesIdleButNotOverBlocked(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.engine.OnOutput(h.id, 40)
	h.screen.set("unmatched")
	flushDebounce(h)
	h.engine.OnOSC(h.id, OSC9)
	h.clock.Advance(0)
	if mustSnap(t, h.engine, h.id).State != StateIdle {
		t.Fatalf("state = %s, want idle from OSC", mustSnap(t, h.engine, h.id).State)
	}

	h.screen.set("Allow this command")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	h.engine.OnOSC(h.id, OSC99)
	h.clock.Advance(0)
	if mustSnap(t, h.engine, h.id).State != StateBlocked {
		t.Fatalf("state = %s, want blocked to win over OSC", mustSnap(t, h.engine, h.id).State)
	}
}

func TestUnauthorizedBlockedSignalIgnored(t *testing.T) {
	reg := Load(LoadOptions{
		DisableLocal: true,
		Bundled: mapFS(map[string][]byte{
			"c.json": validJSON("custom", map[string]any{
				"screen": map[string]any{
					"bottom_lines": 15,
					"buffer":       "active",
					"states": map[string]any{
						"blocked": []any{map[string]string{"id": "b", "pattern": "BLOCKED"}},
						"working": []any{},
						"idle":    []any{},
					},
				},
				"authority": map[string]any{
					"blocked": []string{},
					"working": []string{"activity"},
					"idle":    []string{"screen+quiescence"},
				},
				"match": map[string]any{"executables": []string{"custom"}, "command_patterns": []string{"custom"}},
			}),
			"g.json": validJSON("generic", nil),
		}),
	})
	h := newHarness(t, reg)
	h.engine.OnCommandStart(h.id, "custom")
	h.screen.set("BLOCKED")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State == StateBlocked {
		t.Fatal("unauthorized blocked pattern must not write blocked")
	}
}

func TestUnknownQuietScreenIsIdle(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "claude")
	h.screen.set("totally unknown chrome")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateIdle {
		t.Fatalf("state = %s, want idle", s.State)
	}
}

func TestUnavailableScreenIdleSafe(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "claude")
	h.engine.OnScreenUnavailable(h.id)
	h.clock.Advance(DefaultQuiescence)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateIdle {
		t.Fatalf("state = %s, want idle-safe", s.State)
	}
	if s.State == StateBlocked {
		t.Fatal("unavailable screen must not infer blocked")
	}
}

func TestGenericNeverBlocked(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Executable: "vim", UsingAlt: true})
	h.screen.set("Do you want to Allow this command waiting for input")
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	if mustSnap(t, h.engine, h.id).State == StateBlocked {
		t.Fatal("generic emitted blocked")
	}
	h.clock.Advance(DefaultQuiescence)
	flushDebounce(h)
	if mustSnap(t, h.engine, h.id).State != StateIdle {
		t.Fatalf("generic quiet state = %s, want idle", mustSnap(t, h.engine, h.id).State)
	}
}

func TestGenericNeverBlockedProperty(t *testing.T) {
	reg := Load(LoadOptions{DisableLocal: true})
	fn := func(a, b, c string, n uint8) bool {
		clock := NewManualClock(time.Unix(1_700_000_000, 0))
		screen := newLines(a, b, c)
		e := New(Options{Registry: reg, Clock: clock, Scheduler: clock})
		e.Open("s", screen, &stubInspector{info: ForegroundInfo{Executable: "other", UsingAlt: true}})
		e.OnForeground("s")
		e.OnOutput("s", int(n)+1)
		clock.Advance(DefaultDebounce + DefaultQuiescence)
		s, _ := e.Snapshot("s")
		return s.State != StateBlocked
	}
	if err := quick.Check(fn, nil); err != nil {
		t.Fatal(err)
	}
}

func TestBurstOutputCoalescesScreenEval(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("esc to interrupt")
	before := h.screen.snapshots()
	h.engine.OnOutput(h.id, 10)
	h.clock.Advance(50 * time.Millisecond)
	h.engine.OnOutput(h.id, 10)
	h.clock.Advance(50 * time.Millisecond)
	h.engine.OnOutput(h.id, 10)
	mid := h.screen.snapshots()
	if mid != before {
		t.Fatalf("evaluated during burst: %d -> %d", before, mid)
	}
	h.clock.Advance(DefaultDebounce)
	if h.screen.snapshots() != before+1 {
		t.Fatalf("want one eval after burst, got %d (before %d)", h.screen.snapshots(), before)
	}
}

func TestSustainedOutputStaysWorking(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("unmatched")
	for i := 0; i < 5; i++ {
		h.engine.OnOutput(h.id, 40)
		h.clock.Advance(200 * time.Millisecond)
		if mustSnap(t, h.engine, h.id).State != StateWorking {
			t.Fatalf("tick %d state = %s", i, mustSnap(t, h.engine, h.id).State)
		}
	}
}

func TestRepeatedEvidenceDoesNotResetSince(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set("Allow this command")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	first := mustSnap(t, h.engine, h.id)
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	second := mustSnap(t, h.engine, h.id)
	if !second.Since.Equal(first.Since) {
		t.Fatalf("since reset from %v to %v", first.Since, second.Since)
	}
}

func TestSubscribeOnlyOnTransitionAndOutsideLock(t *testing.T) {
	h := newHarness(t, nil)
	var mu sync.Mutex
	var events []Snapshot
	cancel := h.engine.Subscribe(func(s Snapshot) {
		_, _ = h.engine.Snapshot(s.SessionID)
		mu.Lock()
		events = append(events, s)
		mu.Unlock()
	})
	defer cancel()
	identifyCodex(h)
	h.screen.set("Allow this command")
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	mu.Lock()
	n := len(events)
	mu.Unlock()
	if n == 0 {
		t.Fatal("expected transition")
	}
	h.engine.OnOutput(h.id, 4)
	flushDebounce(h)
	mu.Lock()
	n2 := len(events)
	mu.Unlock()
	if n2 != n {
		t.Fatalf("duplicate transition: %d -> %d", n, n2)
	}
}

func TestLaterOutputReturnsWorkingAfterOSCIdle(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.engine.OnOutput(h.id, 40)
	h.engine.OnOSC(h.id, OSC777)
	h.clock.Advance(0)
	if mustSnap(t, h.engine, h.id).State != StateIdle {
		t.Fatal("want idle")
	}
	h.engine.OnOutput(h.id, 40)
	if mustSnap(t, h.engine, h.id).State != StateWorking {
		t.Fatalf("state = %s, want working after later output", mustSnap(t, h.engine, h.id).State)
	}
}
