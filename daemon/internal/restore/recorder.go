package restore

import (
	"log"
	"reflect"
	"sync"
	"time"
)

// DefaultInterval is how often the recorder compares live sessions against
// what it last wrote. Snapshot writing is off the PTY path entirely, so the
// period only bounds how much of the last moments a crash can lose.
const DefaultInterval = 5 * time.Second

// Observed is one live session as the recorder sees it. It mirrors the fields
// the recorder needs from a session listing without importing the session
// package, keeping the restore policy testable as plain data.
type Observed struct {
	Order int
	Cwd   string
	Memo  string
	Agent string
}

// Entries builds the snapshot entries for a set of live sessions, in the order
// given. A session is recorded only when it has a detected agent whose resume
// command resolves, because an entry that could never be restored is noise the
// next start would have to skip anyway.
func Entries(observed []Observed, overrides map[string]string, now time.Time) []Entry {
	out := make([]Entry, 0, len(observed))
	for _, o := range observed {
		if !Restorable(o.Agent, overrides) {
			continue
		}
		if o.Cwd == "" {
			continue
		}
		out = append(out, Entry{
			Order:  o.Order,
			Cwd:    o.Cwd,
			Memo:   o.Memo,
			Agent:  o.Agent,
			SeenAt: now,
		})
	}
	return out
}

// RecorderOpts configures a Recorder. Observe and Overrides are read on every
// tick so the recorder follows live sessions and live configuration.
type RecorderOpts struct {
	Path      string
	Observe   func() []Observed
	Overrides func() map[string]string
	Logger    *log.Logger
	// Interval defaults to DefaultInterval.
	Interval time.Duration
	// Now defaults to time.Now.
	Now func() time.Time
	// Ticks replaces the internal ticker when set, so tests drive the loop
	// instead of waiting on the wall clock.
	Ticks <-chan time.Time
}

// Recorder keeps the on-disk snapshot in step with the live sessions.
type Recorder struct {
	opts     RecorderOpts
	stop     chan struct{}
	finished chan struct{}
	stopOnce sync.Once

	mu      sync.Mutex
	written []Entry
	// haveWritten separates "wrote an empty set" from "never wrote", so the
	// first tick with no agent sessions still clears a stale snapshot.
	haveWritten bool
}

// StartRecorder begins recording and returns the running Recorder.
func StartRecorder(opts RecorderOpts) *Recorder {
	if opts.Interval <= 0 {
		opts.Interval = DefaultInterval
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	r := &Recorder{
		opts:     opts,
		stop:     make(chan struct{}),
		finished: make(chan struct{}),
	}
	go r.loop()
	return r
}

func (r *Recorder) loop() {
	defer close(r.finished)
	ticks := r.opts.Ticks
	if ticks == nil {
		t := time.NewTicker(r.opts.Interval)
		defer t.Stop()
		ticks = t.C
	}
	for {
		select {
		case <-r.stop:
			return
		case <-ticks:
			r.Tick()
		}
	}
}

// Tick compares the live sessions against the last written set and saves only
// when they differ. It is exported so tests can step the recorder directly.
func (r *Recorder) Tick() {
	if r.opts.Observe == nil {
		return
	}
	var overrides map[string]string
	if r.opts.Overrides != nil {
		overrides = r.opts.Overrides()
	}
	entries := Entries(r.opts.Observe(), overrides, r.opts.Now())

	r.mu.Lock()
	unchanged := r.haveWritten && entriesEqual(r.written, entries)
	r.mu.Unlock()
	if unchanged {
		return
	}

	if err := Save(r.opts.Path, Snapshot{UpdatedAt: r.opts.Now(), Sessions: entries}); err != nil {
		if r.opts.Logger != nil {
			r.opts.Logger.Printf("restore: save snapshot: %v", err)
		}
		return
	}
	r.mu.Lock()
	r.written = entries
	r.haveWritten = true
	r.mu.Unlock()
}

// Stop ends the recording goroutine and writes one final snapshot, so a
// graceful shutdown records the state at the moment of exit.
func (r *Recorder) Stop() {
	r.stopOnce.Do(func() {
		close(r.stop)
		<-r.finished
		r.Tick()
	})
}

// entriesEqual compares two entry sets ignoring SeenAt, which advances on every
// tick and would otherwise make every comparison differ.
func entriesEqual(a, b []Entry) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		x, y := a[i], b[i]
		x.SeenAt, y.SeenAt = time.Time{}, time.Time{}
		if !reflect.DeepEqual(x, y) {
			return false
		}
	}
	return true
}
