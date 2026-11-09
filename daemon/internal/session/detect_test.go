package session

import (
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

func TestObserveOutputDoesNotSnapshotImmediately(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	eng := agentdetect.New(agentdetect.Options{
		Registry:  agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
		Clock:     clock,
		Scheduler: clock,
	})
	scr := &countingScreen{available: true}
	m := &Manager{engine: eng, sessions: map[string]*Session{}}
	s := &Session{ID: "s1", screen: scr, State: StateIdle}
	m.openDetector(s)
	eng.OnCommandStart(s.ID, "codex")
	before := scr.snapshots()
	m.observeOutput(s, 40)
	if scr.snapshots() != before {
		t.Fatal("regex/snapshot ran on output path")
	}
	clock.Advance(agentdetect.DefaultDebounce)
	if scr.snapshots() != before+1 {
		t.Fatalf("snapshots = %d, want %d after debounce", scr.snapshots(), before+1)
	}
}

func TestObserveEventRoutesCommandAndOSC(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	eng := agentdetect.New(agentdetect.Options{
		Registry:  agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
		Clock:     clock,
		Scheduler: clock,
	})
	m := &Manager{engine: eng}
	s := &Session{ID: "s1", State: StateRunning}
	m.openDetector(s)
	m.observeEvent(s, osc.Event{Kind: osc.EventCmdStart, Command: "claude"})
	snap, ok := m.AgentSnapshot(s.ID)
	if !ok || snap.AgentID != agentdetect.IDClaude {
		t.Fatalf("command start not routed: %+v", snap)
	}
	m.observeEvent(s, osc.Event{Kind: osc.EventNotify, OSC: 777, Body: "done"})
	clock.Advance(0)
	if got, _ := m.AgentSnapshot(s.ID); got.State != agentdetect.StateIdle {
		t.Fatalf("OSC 777 not routed: %+v", got)
	}
	m.observeEvent(s, osc.Event{Kind: osc.EventPrompt})
	if got, _ := m.AgentSnapshot(s.ID); got.AgentID != "" || got.State != agentdetect.StateNone {
		t.Fatalf("prompt not routed: %+v", got)
	}
}

func TestDropDetectorRemovesState(t *testing.T) {
	eng := agentdetect.New(agentdetect.Options{
		Registry: agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
	})
	m := &Manager{engine: eng}
	s := &Session{ID: "s1"}
	m.openDetector(s)
	m.dropDetector(s.ID)
	if _, ok := m.AgentSnapshot(s.ID); ok {
		t.Fatal("detector state remained after close")
	}
}

func TestSessionAdaptersAreObservationOnly(t *testing.T) {
	for _, typ := range []reflect.Type{
		reflect.TypeOf(sessionScreen{}),
		reflect.TypeOf(sessionInspector{}),
	} {
		for i := 0; i < typ.NumMethod(); i++ {
			name := strings.ToLower(typ.Method(i).Name)
			if strings.Contains(name, "write") || strings.Contains(name, "kill") {
				t.Fatalf("%s exposes %s", typ, typ.Method(i).Name)
			}
		}
	}
}

func TestNilInspectorPTYFailsSoftly(t *testing.T) {
	info := agentdetect.SessionInspector{}.Inspect()
	if !info.Failed {
		t.Fatal("nil PTY should fail softly")
	}
}

func TestApplyStateConfigDisableAndReenable(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	eng := agentdetect.New(agentdetect.Options{
		Registry:  agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
		Clock:     clock,
		Scheduler: clock,
	})
	m := &Manager{engine: eng, sessions: map[string]*Session{}}
	s := &Session{ID: "s1", State: StateRunning}
	m.openDetector(s)
	m.observeEvent(s, osc.Event{Kind: osc.EventCmdStart, Command: "codex"})
	if got, _ := m.AgentSnapshot(s.ID); got.State == agentdetect.StateNone || got.AgentID == "" {
		t.Fatalf("expected detected agent: %+v", got)
	}

	var snaps []agentdetect.Snapshot
	eng.Subscribe(func(snap agentdetect.Snapshot) { snaps = append(snaps, snap) })
	m.ApplyStateConfig(config.StateConfig{Enabled: false, DebounceMs: 120, QuiescenceMs: 1500, BottomLines: 15})
	if got, _ := m.AgentSnapshot(s.ID); got.State != agentdetect.StateNone {
		t.Fatalf("disable left state %+v", got)
	}
	m.observeEvent(s, osc.Event{Kind: osc.EventNotify, OSC: 9, Body: "wait"})
	clock.Advance(agentdetect.DefaultDebounce)
	if got, _ := m.AgentSnapshot(s.ID); got.State != agentdetect.StateNone {
		t.Fatalf("OSC changed agent state while disabled: %+v", got)
	}

	m.ApplyStateConfig(config.StateConfig{Enabled: true, DebounceMs: 120, QuiescenceMs: 1500, BottomLines: 15})
	clock.Advance(0)
	if got, _ := m.AgentSnapshot(s.ID); got.AgentID != agentdetect.IDCodex {
		t.Fatalf("re-enable did not evaluate: %+v", got)
	}
	_ = snaps
}

func TestSessionInfoOrdinaryNone(t *testing.T) {
	eng := agentdetect.New(agentdetect.Options{
		Registry: agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
	})
	m := &Manager{engine: eng, sessions: map[string]*Session{}, order: []string{"s1"}}
	s := &Session{ID: "s1", State: StateIdle, Cwd: "/tmp"}
	m.sessions[s.ID] = s
	m.openDetector(s)
	info := m.List()[0]
	if info.Agent != "" || info.AgentState != "none" {
		t.Fatalf("list snapshot = %+v", info)
	}
}

type countingScreen struct {
	mu        sync.Mutex
	n         int
	available bool
}

func (c *countingScreen) Feed([]byte) error     { return nil }
func (c *countingScreen) Resize(int, int) error { return nil }
func (c *countingScreen) Close() error          { return nil }
func (c *countingScreen) Snapshot(vtscreen.SnapshotOptions) vtscreen.Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n++
	return vtscreen.Snapshot{Available: c.available, Lines: []string{"unmatched"}}
}
func (c *countingScreen) snapshots() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}
