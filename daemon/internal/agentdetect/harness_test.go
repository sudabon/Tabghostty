package agentdetect

import (
	"sync"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type lineScreen struct {
	mu        sync.Mutex
	lines     []string
	available bool
	active    vtscreen.BufferKind
	calls     int
}

func newLines(lines ...string) *lineScreen {
	return &lineScreen{lines: append([]string(nil), lines...), available: true, active: vtscreen.BufferActive}
}

func (s *lineScreen) Snapshot(opts vtscreen.SnapshotOptions) vtscreen.Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if !s.available {
		return vtscreen.Snapshot{Available: false}
	}
	n := opts.Lines
	if n <= 0 || n > len(s.lines) {
		n = len(s.lines)
	}
	out := append([]string(nil), s.lines[len(s.lines)-n:]...)
	return vtscreen.Snapshot{
		Available: true,
		Buffer:    opts.Buffer,
		Active:    s.active,
		Lines:     out,
	}
}

func (s *lineScreen) set(lines ...string) {
	s.mu.Lock()
	s.lines = append([]string(nil), lines...)
	s.mu.Unlock()
}

func (s *lineScreen) snapshots() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

type stubInspector struct {
	mu   sync.Mutex
	info ForegroundInfo
}

func (s *stubInspector) Inspect() ForegroundInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.info
}

func (s *stubInspector) set(info ForegroundInfo) {
	s.mu.Lock()
	s.info = info
	s.mu.Unlock()
}

type harness struct {
	clock  *ManualClock
	engine *Engine
	screen *lineScreen
	insp   *stubInspector
	id     string
}

func newHarness(t *testing.T, reg *Registry) *harness {
	t.Helper()
	if reg == nil {
		reg = Load(LoadOptions{DisableLocal: true})
	}
	clock := NewManualClock(time.Unix(1_700_000_000, 0))
	h := &harness{
		clock:  clock,
		screen: newLines(""),
		insp:   &stubInspector{info: ForegroundInfo{IsShell: true}},
		id:     "sess-1",
	}
	h.engine = New(Options{Registry: reg, Clock: clock, Scheduler: clock})
	h.engine.Open(h.id, h.screen, h.insp)
	return h
}

func mustSnap(t *testing.T, e *Engine, id string) Snapshot {
	t.Helper()
	s, ok := e.Snapshot(id)
	if !ok {
		t.Fatal("missing snapshot")
	}
	return s
}

func flushDebounce(h *harness) {
	h.clock.Advance(DefaultDebounce)
}
