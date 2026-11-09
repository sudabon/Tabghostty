package restore

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeClock is a deterministic clock the recorder tests advance by hand.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2026, 8, 19, 9, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// recorderHarness wires a recorder to a mutable session list and a tick channel.
type recorderHarness struct {
	t        *testing.T
	path     string
	clock    *fakeClock
	ticks    chan time.Time
	recorder *Recorder

	mu        sync.Mutex
	observed  []Observed
	overrides map[string]string
}

func newRecorderHarness(t *testing.T, observed []Observed) *recorderHarness {
	t.Helper()
	h := &recorderHarness{
		t:        t,
		path:     filepath.Join(t.TempDir(), "restore.json"),
		clock:    newFakeClock(),
		ticks:    make(chan time.Time),
		observed: observed,
	}
	h.recorder = StartRecorder(RecorderOpts{
		Path:      h.path,
		Observe:   h.observe,
		Overrides: h.overrideMap,
		Now:       h.clock.Now,
		Ticks:     h.ticks,
	})
	t.Cleanup(func() { h.recorder.Stop() })
	return h
}

func (h *recorderHarness) observe() []Observed {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]Observed(nil), h.observed...)
}

func (h *recorderHarness) overrideMap() map[string]string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.overrides
}

func (h *recorderHarness) setObserved(observed []Observed) {
	h.mu.Lock()
	h.observed = observed
	h.mu.Unlock()
}

func (h *recorderHarness) setOverrides(overrides map[string]string) {
	h.mu.Lock()
	h.overrides = overrides
	h.mu.Unlock()
}

// tick drives one recorder cycle synchronously.
func (h *recorderHarness) tick() {
	h.t.Helper()
	h.recorder.Tick()
}

func (h *recorderHarness) load() Snapshot {
	h.t.Helper()
	snap, err := Load(h.path)
	if err != nil {
		h.t.Fatalf("Load: %v", err)
	}
	return snap
}

func (h *recorderHarness) modTime() time.Time {
	h.t.Helper()
	info, err := os.Stat(h.path)
	if err != nil {
		h.t.Fatalf("Stat: %v", err)
	}
	return info.ModTime()
}

func TestEntriesKeepsOnlyRestorableAgentSessions(t *testing.T) {
	now := time.Date(2026, 8, 19, 9, 0, 0, 0, time.UTC)
	observed := []Observed{
		{Order: 0, Cwd: "/a", Memo: "one", Agent: "claude"},
		{Order: 1, Cwd: "/b", Agent: ""},        // plain shell
		{Order: 2, Cwd: "/c", Agent: "generic"}, // no resume command
		{Order: 3, Cwd: "/d", Agent: "codex"},
		{Order: 4, Cwd: "", Agent: "claude"}, // no usable directory
	}

	got := Entries(observed, nil, now)

	if len(got) != 2 {
		t.Fatalf("entries = %+v, want 2", got)
	}
	if got[0].Cwd != "/a" || got[0].Agent != "claude" || got[0].Memo != "one" || got[0].Order != 0 {
		t.Fatalf("entry 0 = %+v", got[0])
	}
	if got[1].Cwd != "/d" || got[1].Agent != "codex" || got[1].Order != 3 {
		t.Fatalf("entry 1 = %+v", got[1])
	}
	for i, e := range got {
		if !e.SeenAt.Equal(now) {
			t.Fatalf("entry %d seen_at = %v, want %v", i, e.SeenAt, now)
		}
	}
}

func TestEntriesRespectsDisablingOverride(t *testing.T) {
	observed := []Observed{{Cwd: "/a", Agent: "cursor-agent"}}

	got := Entries(observed, map[string]string{"cursor-agent": ""}, time.Now())

	if len(got) != 0 {
		t.Fatalf("entries = %+v, want none for a disabled agent", got)
	}
}

func TestRecorderWritesOnFirstTick(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})

	h.tick()

	snap := h.load()
	if len(snap.Sessions) != 1 || snap.Sessions[0].Cwd != "/a" {
		t.Fatalf("snapshot = %+v, want one entry for /a", snap.Sessions)
	}
}

func TestRecorderSkipsWriteWhenNothingChanged(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})
	h.tick()
	before := h.modTime()

	// Time moves on, but the session set has not, so SeenAt drift alone must
	// not trigger a write.
	h.clock.Advance(time.Minute)
	h.tick()
	h.clock.Advance(time.Minute)
	h.tick()

	if got := h.modTime(); !got.Equal(before) {
		t.Fatalf("snapshot was rewritten at %v (was %v) with no change", got, before)
	}
}

func TestRecorderWritesWhenCwdChanges(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})
	h.tick()

	h.setObserved([]Observed{{Order: 0, Cwd: "/moved", Agent: "claude"}})
	h.clock.Advance(time.Second)
	h.tick()

	snap := h.load()
	if len(snap.Sessions) != 1 || snap.Sessions[0].Cwd != "/moved" {
		t.Fatalf("snapshot = %+v, want the new cwd", snap.Sessions)
	}
}

func TestRecorderWritesWhenMemoChanges(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})
	h.tick()

	h.setObserved([]Observed{{Order: 0, Cwd: "/a", Memo: "レビュー中", Agent: "claude"}})
	h.tick()

	snap := h.load()
	if len(snap.Sessions) != 1 || snap.Sessions[0].Memo != "レビュー中" {
		t.Fatalf("snapshot = %+v, want the new memo", snap.Sessions)
	}
}

func TestRecorderDropsEntryWhenAgentExits(t *testing.T) {
	h := newRecorderHarness(t, []Observed{
		{Order: 0, Cwd: "/a", Agent: "claude"},
		{Order: 1, Cwd: "/b", Agent: "codex"},
	})
	h.tick()

	// The agent in /a exits and the tab falls back to a plain shell.
	h.setObserved([]Observed{
		{Order: 0, Cwd: "/a", Agent: ""},
		{Order: 1, Cwd: "/b", Agent: "codex"},
	})
	h.tick()

	snap := h.load()
	if len(snap.Sessions) != 1 || snap.Sessions[0].Cwd != "/b" {
		t.Fatalf("snapshot = %+v, want only the codex entry", snap.Sessions)
	}
}

func TestRecorderClearsSnapshotWhenTheLastAgentExits(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})
	h.tick()

	h.setObserved(nil)
	h.tick()

	if snap := h.load(); len(snap.Sessions) != 0 {
		t.Fatalf("snapshot = %+v, want it emptied", snap.Sessions)
	}
}

// A recorder that has never written must still clear a stale file from a
// previous run when the daemon starts with no agent sessions.
func TestRecorderClearsAStaleSnapshotOnFirstTick(t *testing.T) {
	h := newRecorderHarness(t, nil)
	stale := Snapshot{Sessions: []Entry{{Cwd: "/gone", Agent: "claude"}}}
	if err := Save(h.path, stale); err != nil {
		t.Fatal(err)
	}

	h.tick()

	if snap := h.load(); len(snap.Sessions) != 0 {
		t.Fatalf("snapshot = %+v, want the stale entry cleared", snap.Sessions)
	}
}

func TestRecorderFollowsLiveOverrides(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "cursor-agent"}})
	h.tick()
	if snap := h.load(); len(snap.Sessions) != 1 {
		t.Fatalf("snapshot = %+v, want the cursor-agent entry", snap.Sessions)
	}

	h.setOverrides(map[string]string{"cursor-agent": ""})
	h.tick()

	if snap := h.load(); len(snap.Sessions) != 0 {
		t.Fatalf("snapshot = %+v, want the newly disabled agent dropped", snap.Sessions)
	}
}

func TestRecorderStopWritesAFinalSnapshot(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})
	h.tick()

	// A change that no tick observes must still reach disk on shutdown.
	h.setObserved([]Observed{
		{Order: 0, Cwd: "/a", Agent: "claude"},
		{Order: 1, Cwd: "/late", Agent: "codex"},
	})
	h.recorder.Stop()

	snap := h.load()
	if len(snap.Sessions) != 2 || snap.Sessions[1].Cwd != "/late" {
		t.Fatalf("snapshot = %+v, want the final write to include /late", snap.Sessions)
	}
}

func TestRecorderStopIsIdempotent(t *testing.T) {
	h := newRecorderHarness(t, []Observed{{Order: 0, Cwd: "/a", Agent: "claude"}})

	h.recorder.Stop()
	h.recorder.Stop()

	if snap := h.load(); len(snap.Sessions) != 1 {
		t.Fatalf("snapshot = %+v, want one entry", snap.Sessions)
	}
}

func TestRecorderTicksOnItsInterval(t *testing.T) {
	path := filepath.Join(t.TempDir(), "restore.json")
	ticks := make(chan time.Time)
	r := StartRecorder(RecorderOpts{
		Path:      path,
		Observe:   func() []Observed { return []Observed{{Cwd: "/a", Agent: "claude"}} },
		Overrides: func() map[string]string { return nil },
		Ticks:     ticks,
	})
	t.Cleanup(r.Stop)

	ticks <- time.Now()
	// The next send only proceeds once the loop is back at its select, which
	// means the previous tick has completed.
	ticks <- time.Now()

	snap, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(snap.Sessions) != 1 {
		t.Fatalf("snapshot = %+v, want the ticked write", snap.Sessions)
	}
}
