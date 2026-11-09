package agentdetect

import (
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

// Bundled manifest IDs.
const (
	IDClaude  = "claude"
	IDCodex   = "codex"
	IDCursor  = "cursor-agent"
	IDGeneric = "generic"
)

// Timing defaults used when a manifest omits an override.
const (
	DefaultDebounce         = 120 * time.Millisecond
	DefaultQuiescence       = 1500 * time.Millisecond
	DefaultActivityWindow   = 1000 * time.Millisecond
	DefaultActivityMinBytes = 32
)

// debounceMaxWaitFactor bounds how long continuous output can postpone a
// screen evaluation, as a multiple of the debounce interval.
const debounceMaxWaitFactor = 4

// State is the agent turn state, independent of shell command state.
type State string

const (
	StateNone    State = "none"
	StateIdle    State = "idle"
	StateWorking State = "working"
	StateBlocked State = "blocked"
)

// Signal identifies which observation last wrote the current state.
type Signal string

const (
	SignalNone     Signal = ""
	SignalScreen   Signal = "screen"
	SignalActivity Signal = "activity"
	SignalOSC      Signal = "osc"
	SignalCommand  Signal = "command"
	SignalProcess  Signal = "process"
	SignalFallback Signal = "fallback"
)

// Authority is a manifest-declared right to write a state from a signal.
type Authority string

const (
	AuthorityScreen           Authority = "screen"
	AuthorityActivity         Authority = "activity"
	AuthorityOSC              Authority = "osc"
	AuthorityScreenQuiescence Authority = "screen+quiescence"
)

// Snapshot is an immutable view of one session's agent identity and state.
type Snapshot struct {
	SessionID string
	AgentID   string
	State     State
	Since     time.Time
	Signal    Signal
	Detail    string
}

// Clock supplies monotonic timestamps for debounce, activity, and quiescence.
type Clock interface {
	Now() time.Time
}

// Scheduler posts cancellable delayed callbacks.
type Scheduler interface {
	AfterFunc(d time.Duration, fn func()) (cancel func())
}

// ScreenProvider is a read-only VT snapshot seam. It must not write the PTY.
type ScreenProvider interface {
	Snapshot(opts vtscreen.SnapshotOptions) vtscreen.Snapshot
}

// ForegroundInfo is a process-table observation for identity matching.
type ForegroundInfo struct {
	Executable string
	Ancestry   []string
	UsingAlt   bool
	IsShell    bool
	Failed     bool
}

// Inspector inspects the session's foreground process. Failures must not
// fail the session; callers treat Failed as a screen-only / generic fallback.
type Inspector interface {
	Inspect() ForegroundInfo
}

// OSCKind is a completion-notification OSC code.
type OSCKind int

const (
	OSC9   OSCKind = 9
	OSC99  OSCKind = 99
	OSC777 OSCKind = 777
)
