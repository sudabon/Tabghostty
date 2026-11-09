package agentdetect

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestClosedDetectorDropsStateAndTimers(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "codex")
	h.engine.Close(h.id)
	if _, ok := h.engine.Snapshot(h.id); ok {
		t.Fatal("closed detector still snapshotable")
	}
	h.engine.OnOutput(h.id, 40)
	h.clock.Advance(time.Second)
}

func TestClosedGenerationDoesNotCallback(t *testing.T) {
	h := newHarness(t, nil)
	var afterClose atomic.Int32
	opened := make(chan struct{})
	closed := make(chan struct{})
	h.engine.Subscribe(func(s Snapshot) {
		select {
		case <-closed:
			afterClose.Add(1)
		default:
		}
		_ = s
	})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		close(opened)
		for i := 0; i < 200; i++ {
			h.engine.OnCommandStart(h.id, "codex")
			h.engine.OnOutput(h.id, 40)
			h.clock.Advance(DefaultDebounce)
		}
	}()
	go func() {
		defer wg.Done()
		<-opened
		time.Sleep(time.Millisecond)
		h.engine.Close(h.id)
		close(closed)
	}()
	wg.Wait()
	h.clock.Advance(time.Second)
	if afterClose.Load() != 0 {
		t.Fatalf("callbacks after close: %d", afterClose.Load())
	}
}

func TestOpenReplacesPreviousGeneration(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "codex")
	h.engine.Open(h.id, h.screen, h.insp)
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != "" || s.State != StateNone {
		t.Fatalf("replaced detector retained state: %+v", s)
	}
}

func TestConfigureDisableBroadcastsNoneAndReenableEvaluates(t *testing.T) {
	h := newHarness(t, nil)
	var snaps []Snapshot
	h.engine.Subscribe(func(s Snapshot) { snaps = append(snaps, s) })
	h.engine.OnCommandStart(h.id, "codex")
	got := mustSnap(t, h.engine, h.id)
	if got.AgentID != IDCodex || got.State != StateIdle {
		t.Fatalf("before disable: %+v", got)
	}

	h.engine.Configure(RuntimeConfig{Enabled: false, Debounce: DefaultDebounce, Quiescence: DefaultQuiescence, BottomLines: 15})
	got = mustSnap(t, h.engine, h.id)
	if got.AgentID != "" || got.State != StateNone {
		t.Fatalf("disabled snapshot = %+v", got)
	}
	if len(snaps) == 0 || snaps[len(snaps)-1].State != StateNone {
		t.Fatalf("disable did not broadcast none: %#v", snaps)
	}

	before := h.screen.snapshots()
	h.engine.OnOutput(h.id, 40)
	h.clock.Advance(DefaultDebounce)
	if h.screen.snapshots() != before {
		t.Fatal("disabled engine still evaluated the screen")
	}

	h.engine.Configure(RuntimeConfig{Enabled: true, Debounce: DefaultDebounce, Quiescence: DefaultQuiescence, BottomLines: 15})
	h.clock.Advance(0)
	got = mustSnap(t, h.engine, h.id)
	if got.AgentID != IDCodex {
		t.Fatalf("re-enable did not restore identity: %+v", got)
	}
}
