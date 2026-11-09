package agentdetect

import (
	"fmt"
	"time"
)

type patternHit struct {
	id   string
	line int
}

func (d *Detector) recomputeLocked(now time.Time) (bool, Snapshot) {
	prevID, prevState, prevSince := d.identity, d.state, d.since
	if d.identity == "" {
		d.state = StateNone
		d.signal = SignalNone
		d.detail = ""
		d.pendingOSC = 0
		return d.finishLocked(now, prevID, prevState, prevSince)
	}

	man := d.currentManifestLocked()
	if man == nil {
		d.identity = ""
		d.state = StateNone
		d.signal = SignalNone
		d.detail = ""
		d.pendingOSC = 0
		return d.finishLocked(now, prevID, prevState, prevSince)
	}

	blocked, blockDetail := d.blockedEvidence(man)
	working, workSig, workDetail := d.workingEvidence(man, now)
	idleReady, idleDetail := d.idleEvidence(man, now, blocked, working)
	oscIdle := d.oscIdle(man, blocked)

	switch {
	case blocked:
		d.state = StateBlocked
		d.signal = SignalScreen
		d.detail = blockDetail
	case oscIdle:
		d.state = StateIdle
		d.signal = SignalOSC
		d.detail = oscDetail(d.pendingOSC)
	case working:
		d.state = StateWorking
		d.signal = workSig
		d.detail = workDetail
	case idleReady:
		d.state = StateIdle
		d.signal = SignalScreen
		d.detail = idleDetail
	default:
		if prevState == StateWorking || prevState == StateBlocked {
			d.state = StateWorking
			if d.signal == SignalNone || d.signal == SignalScreen && !working {
				d.signal = SignalActivity
			}
		} else if prevState == StateNone || prevID != d.identity {
			d.state = StateIdle
			d.signal = SignalNone
			d.detail = "idle-safe"
		}
	}
	d.pendingOSC = 0
	return d.finishLocked(now, prevID, prevState, prevSince)
}

func (d *Detector) finishLocked(now time.Time, prevID string, prevState State, prevSince time.Time) (bool, Snapshot) {
	changed := prevID != d.identity || prevState != d.state
	if !changed {
		d.since = prevSince
	} else {
		d.since = now
	}
	return changed, d.snapshotLocked()
}

func (d *Detector) blockedEvidence(man *CompiledManifest) (bool, string) {
	if man.ID == IDGeneric {
		return false, ""
	}
	if !man.Allows(StateBlocked, AuthorityScreen) {
		return false, ""
	}
	if !d.hasScreen || !d.lastSnap.Available {
		return false, ""
	}
	hit, ok := matchPatterns(d.lastSnap.Lines, man.Blocked)
	if !ok {
		return false, ""
	}
	if blockedSuppressed(d.lastSnap.Lines, man) {
		return false, ""
	}
	return true, detailOf(hit)
}

// blockedSuppressed reports whether a suppression pattern matches a line below
// the lowest blocked hit. Position matters: a stale status line above a live
// approval prompt must not hide it.
func blockedSuppressed(lines []string, man *CompiledManifest) bool {
	if len(man.BlockedSuppress) == 0 {
		return false
	}
	lowest := -1
	for i, line := range lines {
		for _, p := range man.Blocked {
			if p.RE.MatchString(line) {
				lowest = i
				break
			}
		}
	}
	for _, p := range man.BlockedSuppress {
		for i := len(lines) - 1; i > lowest; i-- {
			if p.RE.MatchString(lines[i]) {
				return true
			}
		}
	}
	return false
}

func (d *Detector) workingEvidence(man *CompiledManifest, now time.Time) (bool, Signal, string) {
	if d.hasScreen && d.lastSnap.Available && man.Allows(StateWorking, AuthorityScreen) {
		if hit, ok := matchPatterns(d.lastSnap.Lines, man.Working); ok {
			return true, SignalScreen, detailOf(hit)
		}
	}
	if man.Allows(StateWorking, AuthorityActivity) && d.activityMet(man, now) {
		return true, SignalActivity, "activity"
	}
	return false, SignalNone, ""
}

func (d *Detector) idleEvidence(man *CompiledManifest, now time.Time, blocked, working bool) (bool, string) {
	if blocked || working {
		return false, ""
	}
	if !man.Allows(StateIdle, AuthorityScreenQuiescence) && !man.Allows(StateIdle, AuthorityScreen) {
		return false, ""
	}
	if !d.quiet(man, now) {
		return false, ""
	}
	if !d.hasScreen {
		return true, "idle-safe"
	}
	if !d.lastSnap.Available {
		return true, "screen-unavailable"
	}
	if hit, ok := matchPatterns(d.lastSnap.Lines, man.Idle); ok {
		return true, detailOf(hit)
	}
	return true, "unknown-screen"
}

func (d *Detector) oscIdle(man *CompiledManifest, blocked bool) bool {
	if blocked || d.pendingOSC == 0 {
		return false
	}
	if !man.OSCAuthoritative {
		return false
	}
	return man.Allows(StateIdle, AuthorityOSC)
}

func (d *Detector) quiet(man *CompiledManifest, now time.Time) bool {
	if d.lastOutput.IsZero() {
		return true
	}
	return !now.Before(d.lastOutput.Add(d.quiescenceOf(man)))
}

func (d *Detector) activityMet(man *CompiledManifest, now time.Time) bool {
	d.trimSamplesLocked(now)
	sum := 0
	for _, s := range d.samples {
		sum += s.n
	}
	return sum >= man.ActivityMinBytes
}

func matchPatterns(lines []string, patterns []CompiledPattern) (patternHit, bool) {
	for _, p := range patterns {
		for i, line := range lines {
			if p.RE.MatchString(line) {
				return patternHit{id: p.ID, line: i}, true
			}
		}
	}
	return patternHit{}, false
}

func detailOf(h patternHit) string {
	return fmt.Sprintf("pattern=%s line=%d", h.id, h.line)
}

func oscDetail(kind OSCKind) string {
	if kind == 0 {
		return "osc"
	}
	return fmt.Sprintf("osc=%d", kind)
}
