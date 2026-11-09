package vtscreen

import "errors"

// BufferKind selects which visible buffer a snapshot reads.
type BufferKind string

const (
	BufferActive    BufferKind = "active"
	BufferPrimary   BufferKind = "primary"
	BufferAlternate BufferKind = "alternate"
)

// ErrUnavailable is returned when the screen model cannot be used.
var ErrUnavailable = errors.New("vtscreen: model unavailable")

// SnapshotOptions controls which visible rows a snapshot returns.
type SnapshotOptions struct {
	Buffer BufferKind
	Lines  int
}

// Snapshot is an immutable copy of normalized visible rows.
type Snapshot struct {
	Available bool
	Buffer    BufferKind
	Active    BufferKind
	Cols      int
	Rows      int
	Lines     []string
}

// Screen is the session-owned headless terminal model.
type Screen interface {
	Feed(data []byte) error
	Resize(cols, rows int) error
	Snapshot(opts SnapshotOptions) Snapshot
	Close() error
}

// Factory constructs a screen from a PTY's initial geometry.
// A returned error must not prevent session creation; callers treat the model as unavailable.
type Factory func(cols, rows int) (Screen, error)
