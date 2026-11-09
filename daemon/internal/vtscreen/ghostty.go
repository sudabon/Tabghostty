//go:build ghostty

// Tabghostty: libghostty-vt screen model (openspec/changes/phase6-daemon-ghostty-screen design D1).
// Not part of upstream webtabinal; see daemon/UPSTREAM.md.

package vtscreen

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"go.mitchellh.com/libghostty"
)

// ModelName names the screen model this build uses.
const ModelName = "ghostty"

// LibraryVersion reports the linked libghostty-vt version (ghostty_version()).
func LibraryVersion() string {
	return libghostty.Version()
}

// Open constructs a libghostty-vt backed screen with logging and geometry options.
func Open(opts Options) (Screen, error) {
	return openGhostty(opts)
}

func openGhostty(opts Options) (screen Screen, err error) {
	if opts.Cols <= 0 || opts.Rows <= 0 || opts.Cols > 0xFFFF || opts.Rows > 0xFFFF {
		return nil, ErrUnavailable
	}
	defer func() {
		if rec := recover(); rec != nil {
			err = ErrUnavailable
			screen = nil
			logFailure(opts.Logger, opts.Name, "construct", rec, defaultFailLogInterval, new(time.Time))
		}
	}()
	// No effects are registered, so terminal replies (DA/DSR/...) are dropped
	// like drainEmulatorReplies does for the charmbracelet model.
	term, terr := libghostty.NewTerminal(
		libghostty.WithSize(uint16(opts.Cols), uint16(opts.Rows)),
		libghostty.WithMaxScrollbackLines(0),
	)
	if terr != nil {
		logFailure(opts.Logger, opts.Name, "construct", terr, defaultFailLogInterval, new(time.Time))
		return nil, ErrUnavailable
	}
	s := &ghosttyScreen{
		term:            term,
		cols:            opts.Cols,
		rows:            opts.Rows,
		primary:         make([]string, opts.Rows),
		alternate:       make([]string, opts.Rows),
		available:       true,
		dirty:           true,
		logger:          opts.Logger,
		name:            opts.Name,
		failLogInterval: defaultFailLogInterval,
	}
	return s, nil
}

// ghosttyScreen keeps normalized copies of the primary and alternate screens like
// emulatorScreen does. libghostty only exposes the active screen's grid, so the
// screen being left is captured right before each alternate-screen transition and
// the active screen is captured lazily when a snapshot is taken.
type ghosttyScreen struct {
	mu              sync.Mutex
	term            *libghostty.Terminal
	cols            int
	rows            int
	primary         []string
	alternate       []string
	altOn           bool
	dirty           bool
	available       bool
	closed          bool
	logger          *log.Logger
	name            string
	failLogInterval time.Duration
	lastFailLog     time.Time
}

func (s *ghosttyScreen) Feed(data []byte) (err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
		return ErrUnavailable
	}
	defer func() {
		if rec := recover(); rec != nil {
			s.markUnavailableLocked("panic", rec)
			err = ErrUnavailable
		}
	}()
	for _, chunk := range splitAltTransitions(data) {
		transition := altScreenSeqLen(chunk) == len(chunk)
		if transition {
			if cerr := s.captureIfDirtyLocked(); cerr != nil {
				s.markUnavailableLocked("capture", cerr)
				return ErrUnavailable
			}
		}
		s.term.VTWrite(chunk)
		s.dirty = true
	}
	return nil
}

func (s *ghosttyScreen) Resize(cols, rows int) (err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
		return ErrUnavailable
	}
	if cols <= 0 || rows <= 0 || cols > 0xFFFF || rows > 0xFFFF {
		s.markUnavailableLocked("resize", fmt.Errorf("invalid geometry %dx%d", cols, rows))
		return ErrUnavailable
	}
	defer func() {
		if rec := recover(); rec != nil {
			s.markUnavailableLocked("panic", rec)
			err = ErrUnavailable
		}
	}()
	if rerr := s.term.Resize(uint16(cols), uint16(rows), 0, 0); rerr != nil {
		s.markUnavailableLocked("resize", rerr)
		return ErrUnavailable
	}
	s.cols, s.rows = cols, rows
	s.primary = resizeLines(s.primary, rows)
	s.alternate = resizeLines(s.alternate, rows)
	s.dirty = true
	return nil
}

func (s *ghosttyScreen) Snapshot(opts SnapshotOptions) (snap Snapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
		return Snapshot{Available: false}
	}
	defer func() {
		if rec := recover(); rec != nil {
			s.markUnavailableLocked("panic", rec)
			snap = Snapshot{Available: false}
		}
	}()
	if err := s.captureIfDirtyLocked(); err != nil {
		s.markUnavailableLocked("capture", err)
		return Snapshot{Available: false}
	}
	kind := opts.Buffer
	if kind == "" {
		kind = BufferActive
	}
	active := BufferPrimary
	if s.altOn {
		active = BufferAlternate
	}
	resolved := kind
	lines := s.primary
	switch kind {
	case BufferAlternate:
		lines = s.alternate
	case BufferActive:
		resolved = active
		if s.altOn {
			lines = s.alternate
		}
	default:
		resolved = BufferPrimary
	}
	k := opts.Lines
	if k <= 0 || k > len(lines) {
		k = len(lines)
	}
	start := len(lines) - k
	out := append([]string(nil), lines[start:]...)
	return Snapshot{
		Available: true,
		Buffer:    resolved,
		Active:    active,
		Cols:      s.cols,
		Rows:      s.rows,
		Lines:     out,
	}
}

func (s *ghosttyScreen) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	s.available = false
	s.term.Close()
	return nil
}

// captureIfDirtyLocked stores the active screen's normalized rows if anything
// was written since the last capture.
func (s *ghosttyScreen) captureIfDirtyLocked() error {
	if !s.dirty {
		return nil
	}
	screen, err := s.term.ActiveScreen()
	if err != nil {
		return err
	}
	lines, err := s.readActiveLinesLocked()
	if err != nil {
		return err
	}
	s.altOn = screen == libghostty.ScreenAlternate
	if s.altOn {
		s.alternate = lines
	} else {
		s.primary = lines
	}
	s.dirty = false
	return nil
}

// readActiveLinesLocked normalizes the active area the same way cellsToLines does:
// wide-character continuation cells are skipped, empty cells become spaces, a
// cell's grapheme cluster (base plus combining marks) is kept together, and
// trailing spaces are trimmed. Tabghostty's ScreenNormalizer applies the same rules.
func (s *ghosttyScreen) readActiveLinesLocked() ([]string, error) {
	lines := make([]string, s.rows)
	var b strings.Builder
	for y := 0; y < s.rows; y++ {
		b.Reset()
		for x := 0; x < s.cols; x++ {
			ref, err := s.term.GridRef(libghostty.Point{Tag: libghostty.PointTagActive, X: uint16(x), Y: uint32(y)})
			if err != nil {
				return nil, err
			}
			cell, err := ref.Cell()
			if err != nil {
				return nil, err
			}
			wide, err := cell.Wide()
			if err != nil {
				return nil, err
			}
			switch wide {
			case libghostty.CellWideSpacerTail:
				continue
			case libghostty.CellWideSpacerHead:
				b.WriteByte(' ')
				continue
			}
			codepoints, err := ref.Graphemes()
			if err != nil {
				return nil, err
			}
			if len(codepoints) == 0 {
				b.WriteByte(' ')
				continue
			}
			for _, cp := range codepoints {
				b.WriteRune(rune(cp))
			}
		}
		lines[y] = strings.TrimRight(b.String(), " ")
	}
	return lines, nil
}

func (s *ghosttyScreen) markUnavailableLocked(kind string, detail any) {
	s.available = false
	logFailure(s.logger, s.name, kind, detail, s.failLogInterval, &s.lastFailLog)
}
