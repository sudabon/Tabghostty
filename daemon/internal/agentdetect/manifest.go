package agentdetect

import (
	"regexp"
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

// CompiledManifest is the immutable, load-time-validated form of a schema v1 manifest.
type CompiledManifest struct {
	ID              string
	DisplayName     string
	SchemaVersion   int
	Executables     []string
	CommandMatchers []*regexp.Regexp
	ScreenBuffer    vtscreen.BufferKind
	BottomLines     int
	HasBottomLines  bool
	Blocked         []CompiledPattern
	// BlockedSuppress patterns veto blocked evidence when they match a line below
	// every blocked hit, e.g. a live "esc to interrupt" status line under stale
	// approval-like prose that is still in the bottom lines.
	BlockedSuppress  []CompiledPattern
	Working          []CompiledPattern
	Idle             []CompiledPattern
	BlockedAuth      []Authority
	WorkingAuth      []Authority
	IdleAuth         []Authority
	OSCAuthoritative bool
	Quiescence       time.Duration
	HasQuiescence    bool
	ActivityWindow   time.Duration
	ActivityMinBytes int
	VerifiedAgainst  []string
	Notes            string
}

// CompiledPattern is a load-time compiled screen regex with a diagnostic ID.
type CompiledPattern struct {
	ID string
	RE *regexp.Regexp
}

func (m *CompiledManifest) Allows(state State, auth Authority) bool {
	if m == nil {
		return false
	}
	var list []Authority
	switch state {
	case StateBlocked:
		list = m.BlockedAuth
	case StateWorking:
		list = m.WorkingAuth
	case StateIdle:
		list = m.IdleAuth
	default:
		return false
	}
	for _, a := range list {
		if a == auth {
			return true
		}
	}
	return false
}

func (m *CompiledManifest) SnapshotOpts() vtscreen.SnapshotOptions {
	buf := m.ScreenBuffer
	if buf == "" {
		buf = vtscreen.BufferActive
	}
	lines := m.BottomLines
	if lines <= 0 {
		lines = 15
	}
	return vtscreen.SnapshotOptions{Buffer: buf, Lines: lines}
}
