package agentdetect

import (
	"sync"
	"sync/atomic"
	"time"
)

// Options configures a manager-level engine.
type Options struct {
	Registry    *Registry
	Clock       Clock
	Scheduler   Scheduler
	Debounce    time.Duration
	Quiescence  time.Duration
	BottomLines int
	Enabled     *bool
}

// RuntimeConfig is the subset of state settings applied after a config commit.
type RuntimeConfig struct {
	Enabled     bool
	Debounce    time.Duration
	Quiescence  time.Duration
	BottomLines int
}

// Engine owns per-session detectors and transition subscribers.
type Engine struct {
	registry    *Registry
	clock       Clock
	scheduler   Scheduler
	debounce    time.Duration
	quiescence  time.Duration
	bottomLines int
	enabled     atomic.Bool

	mu        sync.Mutex
	detectors map[string]*Detector
	subs      map[int]func(Snapshot)
	nextSub   int
}

// New constructs an engine. Missing clock/scheduler/registry use production defaults.
func New(opts Options) *Engine {
	if opts.Registry == nil {
		opts.Registry = Load(LoadOptions{DisableLocal: true})
	}
	if opts.Clock == nil {
		opts.Clock = SystemClock{}
	}
	if opts.Scheduler == nil {
		if mc, ok := opts.Clock.(*ManualClock); ok {
			opts.Scheduler = mc
		} else {
			opts.Scheduler = SystemScheduler{}
		}
	}
	if opts.Debounce <= 0 {
		opts.Debounce = DefaultDebounce
	}
	if opts.Quiescence == 0 {
		opts.Quiescence = DefaultQuiescence
	}
	if opts.BottomLines <= 0 {
		opts.BottomLines = 15
	}
	e := &Engine{
		registry:    opts.Registry,
		clock:       opts.Clock,
		scheduler:   opts.Scheduler,
		debounce:    opts.Debounce,
		quiescence:  opts.Quiescence,
		bottomLines: opts.BottomLines,
		detectors:   map[string]*Detector{},
		subs:        map[int]func(Snapshot){},
	}
	e.enabled.Store(opts.Enabled == nil || *opts.Enabled)
	return e
}

func (e *Engine) isEnabled() bool { return e.enabled.Load() }

// Configure applies enabled/timing/line defaults atomically. Manifest directory
// changes are ignored here; they require a daemon restart.
func (e *Engine) Configure(cfg RuntimeConfig) {
	if cfg.Debounce <= 0 {
		cfg.Debounce = DefaultDebounce
	}
	if cfg.BottomLines <= 0 {
		cfg.BottomLines = 15
	}
	wasEnabled := e.enabled.Load()
	e.mu.Lock()
	e.debounce = cfg.Debounce
	e.quiescence = cfg.Quiescence
	e.bottomLines = cfg.BottomLines
	dets := make([]*Detector, 0, len(e.detectors))
	for _, d := range e.detectors {
		dets = append(dets, d)
	}
	e.mu.Unlock()
	e.enabled.Store(cfg.Enabled)

	switch {
	case !cfg.Enabled:
		for _, d := range dets {
			d.Disable()
		}
	case !wasEnabled:
		for _, d := range dets {
			d.EvaluateNow()
		}
	default:
		for _, d := range dets {
			d.Reschedule()
		}
	}
}

func (e *Engine) Registry() *Registry { return e.registry }

// Open creates or replaces the detector for a live session.
func (e *Engine) Open(sessionID string, screen ScreenProvider, inspector Inspector) *Detector {
	if sessionID == "" {
		return nil
	}
	d := newDetector(e, sessionID, screen, inspector)
	e.mu.Lock()
	if prev := e.detectors[sessionID]; prev != nil {
		e.mu.Unlock()
		prev.Close()
		e.mu.Lock()
	}
	e.detectors[sessionID] = d
	e.mu.Unlock()
	return d
}

// Close cancels timers and removes detector state for a session.
func (e *Engine) Close(sessionID string) {
	e.mu.Lock()
	d := e.detectors[sessionID]
	delete(e.detectors, sessionID)
	e.mu.Unlock()
	if d != nil {
		d.Close()
	}
}

// Snapshot returns the current immutable snapshot for a live detector.
func (e *Engine) Snapshot(sessionID string) (Snapshot, bool) {
	d := e.lookup(sessionID)
	if d == nil {
		return Snapshot{}, false
	}
	return d.Snapshot()
}

// Subscribe registers a transition callback invoked outside engine locks.
func (e *Engine) Subscribe(fn func(Snapshot)) (cancel func()) {
	if fn == nil {
		return func() {}
	}
	e.mu.Lock()
	e.nextSub++
	id := e.nextSub
	e.subs[id] = fn
	e.mu.Unlock()
	return func() {
		e.mu.Lock()
		delete(e.subs, id)
		e.mu.Unlock()
	}
}

func (e *Engine) lookup(sessionID string) *Detector {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.detectors[sessionID]
}

func (e *Engine) notify(snap Snapshot) {
	e.mu.Lock()
	subs := make([]func(Snapshot), 0, len(e.subs))
	for _, fn := range e.subs {
		subs = append(subs, fn)
	}
	e.mu.Unlock()
	for _, fn := range subs {
		fn(snap)
	}
}

func (e *Engine) OnOutput(sessionID string, n int) {
	if d := e.lookup(sessionID); d != nil {
		d.OnOutput(n)
	}
}

func (e *Engine) OnOSC(sessionID string, kind OSCKind) {
	if d := e.lookup(sessionID); d != nil {
		d.OnOSC(kind)
	}
}

func (e *Engine) OnCommandStart(sessionID, command string) {
	if d := e.lookup(sessionID); d != nil {
		d.OnCommandStart(command)
	}
}

func (e *Engine) OnCommandEnd(sessionID string) {
	if d := e.lookup(sessionID); d != nil {
		d.OnCommandEnd()
	}
}

func (e *Engine) OnPrompt(sessionID string) {
	if d := e.lookup(sessionID); d != nil {
		d.OnPrompt()
	}
}

func (e *Engine) OnForeground(sessionID string) {
	if d := e.lookup(sessionID); d != nil {
		d.OnForeground()
	}
}

func (e *Engine) OnForegroundInfo(sessionID string, info ForegroundInfo) {
	if d := e.lookup(sessionID); d != nil {
		d.ApplyForeground(info)
	}
}

func (e *Engine) OnResize(sessionID string) {
	if d := e.lookup(sessionID); d != nil {
		d.OnResize()
	}
}

func (e *Engine) OnScreenUnavailable(sessionID string) {
	if d := e.lookup(sessionID); d != nil {
		d.OnScreenUnavailable()
	}
}
