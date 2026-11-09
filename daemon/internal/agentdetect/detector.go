package agentdetect

import (
	"sync"
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type activitySample struct {
	t time.Time
	n int
}

// Detector is the per-session state machine.
type Detector struct {
	engine    *Engine
	sessionID string
	screen    ScreenProvider
	inspector Inspector

	mu              sync.Mutex
	inFlight        sync.WaitGroup
	gen             uint64
	closed          bool
	identity        string
	provisional     bool
	commandLine     string
	state           State
	since           time.Time
	signal          Signal
	detail          string
	samples         []activitySample
	lastOutput      time.Time
	pendingOSC      OSCKind
	cancelDebounce  func()
	debounceSince   time.Time
	cancelQuiet     func()
	lastSnap        vtscreen.Snapshot
	hasScreen       bool
	screenForcedOff bool
}

func newDetector(e *Engine, sessionID string, screen ScreenProvider, inspector Inspector) *Detector {
	now := e.clock.Now()
	return &Detector{
		engine:    e,
		sessionID: sessionID,
		screen:    screen,
		inspector: inspector,
		state:     StateNone,
		since:     now,
	}
}

func (d *Detector) Snapshot() (Snapshot, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return Snapshot{}, false
	}
	if !d.engine.isEnabled() {
		return Snapshot{
			SessionID: d.sessionID,
			State:     StateNone,
			Since:     d.since,
		}, true
	}
	return d.snapshotLocked(), true
}

func (d *Detector) snapshotLocked() Snapshot {
	return Snapshot{
		SessionID: d.sessionID,
		AgentID:   d.identity,
		State:     d.state,
		Since:     d.since,
		Signal:    d.signal,
		Detail:    d.detail,
	}
}

// Close cancels timers and drops state. Callbacks from this generation are ignored.
func (d *Detector) Close() {
	d.mu.Lock()
	d.closed = true
	d.gen++
	cancel := d.cancelDebounce
	d.cancelDebounce = nil
	quiet := d.cancelQuiet
	d.cancelQuiet = nil
	d.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if quiet != nil {
		quiet()
	}
	d.inFlight.Wait()
}

// Disable cancels pending evaluation and broadcasts none without closing the detector.
func (d *Detector) Disable() {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.gen++
	cancel := d.cancelDebounce
	d.cancelDebounce = nil
	quiet := d.cancelQuiet
	d.cancelQuiet = nil
	prevID, prevState, prevSince := d.identity, d.state, d.since
	d.identity = ""
	d.state = StateNone
	d.signal = SignalNone
	d.detail = ""
	d.pendingOSC = 0
	now := d.engine.clock.Now()
	changed, snap := d.finishLocked(now, prevID, prevState, prevSince)
	gen := d.gen
	d.finish(changed, snap, gen)
	if cancel != nil {
		cancel()
	}
	if quiet != nil {
		quiet()
	}
}

// EvaluateNow schedules an immediate screen evaluation for re-enable.
func (d *Detector) EvaluateNow() {
	info := ForegroundInfo{Failed: true}
	if d.inspector != nil {
		info = d.inspector.Inspect()
	}
	d.mu.Lock()
	if d.closed || !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	d.applyForegroundLocked(info, false)
	if d.identity == "" && d.commandLine != "" && d.engine.registry != nil {
		id, sig := d.engine.registry.Resolve(d.commandLine, info)
		d.identity = id
		d.provisional = id != ""
		if id != "" {
			d.signal = sig
		}
	}
	gen := d.gen
	d.rescheduleLocked(0, gen)
	d.mu.Unlock()
}

// Reschedule applies current engine debounce/quiescence timers.
func (d *Detector) Reschedule() {
	d.mu.Lock()
	if d.closed || !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	now := d.engine.clock.Now()
	gen := d.gen
	d.rescheduleLocked(d.engine.debounce, gen)
	d.rescheduleQuietLocked(now, gen)
	d.mu.Unlock()
}

func (d *Detector) finish(changed bool, snap Snapshot, gen uint64) {
	if !changed {
		d.mu.Unlock()
		return
	}
	d.inFlight.Add(1)
	d.mu.Unlock()
	defer d.inFlight.Done()
	d.mu.Lock()
	live := !d.closed && d.gen == gen
	d.mu.Unlock()
	if live {
		d.engine.notify(snap)
	}
}

func (d *Detector) OnOutput(n int) {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	now := d.engine.clock.Now()
	if n < 0 {
		n = 0
	}
	d.samples = append(d.samples, activitySample{t: now, n: n})
	d.lastOutput = now
	d.trimSamplesLocked(now)
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	gen := d.gen
	changed, snap := d.recomputeLocked(now)
	d.rescheduleLocked(d.engine.debounce, gen)
	d.rescheduleQuietLocked(now, gen)
	d.finish(changed, snap, gen)
}

func (d *Detector) OnOSC(kind OSCKind) {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.pendingOSC = kind
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	gen := d.gen
	d.rescheduleLocked(0, gen)
	d.mu.Unlock()
}

func (d *Detector) OnCommandStart(command string) {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.commandLine = command
	id, sig := d.engine.registry.Resolve(command, ForegroundInfo{})
	d.identity = id
	d.provisional = id != ""
	if id != "" {
		d.signal = sig
	}
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	now := d.engine.clock.Now()
	gen := d.gen
	changed, snap := d.recomputeLocked(now)
	d.finish(changed, snap, gen)
}

func (d *Detector) OnCommandEnd() {
	d.clearIfAgentGone(true)
}

func (d *Detector) OnPrompt() {
	d.clearIfAgentGone(true)
}

func (d *Detector) OnForeground() {
	info := ForegroundInfo{Failed: true}
	if d.inspector != nil {
		info = d.inspector.Inspect()
	}
	d.ApplyForeground(info)
}

func (d *Detector) ApplyForeground(info ForegroundInfo) {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.applyForegroundLocked(info, false)
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	now := d.engine.clock.Now()
	gen := d.gen
	changed, snap := d.recomputeLocked(now)
	d.finish(changed, snap, gen)
}

func (d *Detector) OnResize() {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	gen := d.gen
	d.rescheduleLocked(d.engine.debounce, gen)
	d.mu.Unlock()
}

func (d *Detector) OnScreenUnavailable() {
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.screenForcedOff = true
	d.hasScreen = true
	d.lastSnap = vtscreen.Snapshot{Available: false}
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	now := d.engine.clock.Now()
	gen := d.gen
	changed, snap := d.recomputeLocked(now)
	d.finish(changed, snap, gen)
}

func (d *Detector) clearIfAgentGone(promptReturned bool) {
	info := ForegroundInfo{Failed: true}
	if d.inspector != nil {
		info = d.inspector.Inspect()
	}
	d.mu.Lock()
	if d.closed {
		d.mu.Unlock()
		return
	}
	d.applyForegroundLocked(info, promptReturned)
	if !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	now := d.engine.clock.Now()
	gen := d.gen
	changed, snap := d.recomputeLocked(now)
	d.finish(changed, snap, gen)
}

func (d *Detector) applyForegroundLocked(info ForegroundInfo, promptReturned bool) {
	cmd := d.commandLine
	if promptReturned {
		cmd = ""
		d.commandLine = ""
	}
	id, sig := d.engine.registry.Resolve(cmd, info)
	if info.Failed && !promptReturned {
		return
	}
	d.identity = id
	d.provisional = id != "" && sig != SignalProcess
}

// rescheduleLocked debounces screen evaluation. Agents such as Codex redraw
// their status line faster than the debounce interval, so the trailing edge is
// capped at debounceMaxWait after the first deferred request; otherwise the
// detector would keep judging a stale snapshot for as long as output flows.
func (d *Detector) rescheduleLocked(delay time.Duration, gen uint64) {
	if d.cancelDebounce != nil {
		d.cancelDebounce()
		d.cancelDebounce = nil
	}
	now := d.engine.clock.Now()
	if d.debounceSince.IsZero() {
		d.debounceSince = now
	}
	if deadline := d.debounceSince.Add(debounceMaxWait(d.engine.debounce)); now.Add(delay).After(deadline) {
		delay = deadline.Sub(now)
		if delay < 0 {
			delay = 0
		}
	}
	d.cancelDebounce = d.engine.scheduler.AfterFunc(delay, func() {
		d.evaluateScreen(gen)
	})
}

func (d *Detector) rescheduleQuietLocked(now time.Time, gen uint64) {
	if d.cancelQuiet != nil {
		d.cancelQuiet()
		d.cancelQuiet = nil
	}
	man := d.currentManifestLocked()
	if man == nil || d.identity == "" {
		return
	}
	delay := d.quiescenceOf(man)
	if !d.lastOutput.IsZero() {
		delay = d.lastOutput.Add(d.quiescenceOf(man)).Sub(now)
		if delay < 0 {
			delay = 0
		}
	}
	d.cancelQuiet = d.engine.scheduler.AfterFunc(delay, func() {
		d.evaluateScreen(gen)
	})
}

func (d *Detector) evaluateScreen(gen uint64) {
	d.mu.Lock()
	if d.closed || d.gen != gen || !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	man := d.currentManifestLocked()
	screen := d.screen
	forcedOff := d.screenForcedOff
	opts := d.snapshotOptsLocked(man)
	d.mu.Unlock()

	var snap vtscreen.Snapshot
	if !forcedOff && screen != nil && man != nil {
		snap = screen.Snapshot(opts)
	} else if forcedOff {
		snap = vtscreen.Snapshot{Available: false}
	}

	d.mu.Lock()
	if d.closed || d.gen != gen || !d.engine.isEnabled() {
		d.mu.Unlock()
		return
	}
	d.lastSnap = snap
	d.hasScreen = true
	d.debounceSince = time.Time{}
	now := d.engine.clock.Now()
	changed, out := d.recomputeLocked(now)
	d.finish(changed, out, gen)
}

func (d *Detector) currentManifestLocked() *CompiledManifest {
	if d.identity == "" || d.engine.registry == nil {
		return nil
	}
	if m, ok := d.engine.registry.Manifest(d.identity); ok {
		return m
	}
	return d.engine.registry.Generic()
}

func (d *Detector) quiescenceOf(man *CompiledManifest) time.Duration {
	if man != nil && man.HasQuiescence {
		return man.Quiescence
	}
	return d.engine.quiescence
}

func (d *Detector) snapshotOptsLocked(man *CompiledManifest) vtscreen.SnapshotOptions {
	if man == nil {
		return vtscreen.SnapshotOptions{Lines: d.engine.bottomLines}
	}
	opts := man.SnapshotOpts()
	if !man.HasBottomLines {
		opts.Lines = d.engine.bottomLines
	}
	return opts
}

func debounceMaxWait(debounce time.Duration) time.Duration {
	return debounceMaxWaitFactor * debounce
}

func (d *Detector) trimSamplesLocked(now time.Time) {
	man := d.currentManifestLocked()
	window := DefaultActivityWindow
	if man != nil {
		window = man.ActivityWindow
	}
	cutoff := now.Add(-window)
	i := 0
	for i < len(d.samples) && d.samples[i].t.Before(cutoff) {
		i++
	}
	if i > 0 {
		d.samples = append([]activitySample(nil), d.samples[i:]...)
	}
}
