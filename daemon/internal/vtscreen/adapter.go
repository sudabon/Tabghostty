package vtscreen

import (
	"fmt"
	"io"
	"log"
	"strings"
	"sync"
	"time"

	xvt "github.com/charmbracelet/x/vt"
)

const defaultFailLogInterval = 10 * time.Second

// Options configures a headless screen model.
type Options struct {
	Cols   int
	Rows   int
	Logger *log.Logger
	Name   string
}

// New constructs a screen from the PTY's initial geometry.
func New(cols, rows int) (Screen, error) {
	return Open(Options{Cols: cols, Rows: rows})
}

// openCharm constructs the charmbracelet/x/vt screen with logging and geometry options.
// Open selects it in the default build (open_charm.go); the ghostty build selects ghostty.go.
// Tabghostty: renamed from Open (see daemon/UPSTREAM.md).
func openCharm(opts Options) (screen Screen, err error) {
	if opts.Cols <= 0 || opts.Rows <= 0 {
		return nil, ErrUnavailable
	}
	defer func() {
		if rec := recover(); rec != nil {
			err = ErrUnavailable
			screen = nil
			logFailure(opts.Logger, opts.Name, "construct", rec, defaultFailLogInterval, new(time.Time))
		}
	}()
	emu := xvt.NewEmulator(opts.Cols, opts.Rows)
	emu.SetScrollbackSize(1)
	// x/vt answers DA1/DSR/DECRQM by writing to an unbuffered io.Pipe.
	// Nobody reads that pipe for snapshots, so drain replies or Feed blocks
	// the PTY read loop and TUI apps (claude, agent) hang on startup.
	go drainEmulatorReplies(emu)
	s := &emulatorScreen{
		emu:             emu,
		cols:            opts.Cols,
		rows:            opts.Rows,
		primary:         make([]string, opts.Rows),
		alternate:       make([]string, opts.Rows),
		available:       true,
		logger:          opts.Logger,
		name:            opts.Name,
		failLogInterval: defaultFailLogInterval,
	}
	s.write = func(p []byte) error {
		_, err := emu.Write(p)
		return err
	}
	s.resizeFn = func(c, r int) error {
		emu.Resize(c, r)
		return nil
	}
	s.closeFn = emu.Close
	s.captureLocked()
	return s, nil
}

type emulatorScreen struct {
	mu              sync.Mutex
	emu             *xvt.Emulator
	cols            int
	rows            int
	primary         []string
	alternate       []string
	altOn           bool
	available       bool
	closed          bool
	write           func([]byte) error
	resizeFn        func(cols, rows int) error
	closeFn         func() error
	logger          *log.Logger
	name            string
	failLogInterval time.Duration
	lastFailLog     time.Time
}

func drainEmulatorReplies(emu *xvt.Emulator) {
	_, _ = io.Copy(io.Discard, emu)
}

func (s *emulatorScreen) Feed(data []byte) (err error) {
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
		if werr := s.write(chunk); werr != nil {
			s.markUnavailableLocked("feed", werr)
			return ErrUnavailable
		}
		s.captureLocked()
	}
	return nil
}

func (s *emulatorScreen) Resize(cols, rows int) (err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
		return ErrUnavailable
	}
	if cols <= 0 || rows <= 0 {
		s.markUnavailableLocked("resize", fmt.Errorf("invalid geometry %dx%d", cols, rows))
		return ErrUnavailable
	}
	defer func() {
		if rec := recover(); rec != nil {
			s.markUnavailableLocked("panic", rec)
			err = ErrUnavailable
		}
	}()
	if rerr := s.resizeFn(cols, rows); rerr != nil {
		s.markUnavailableLocked("resize", rerr)
		return ErrUnavailable
	}
	s.cols, s.rows = cols, rows
	s.primary = resizeLines(s.primary, rows)
	s.alternate = resizeLines(s.alternate, rows)
	s.captureLocked()
	return nil
}

func (s *emulatorScreen) Snapshot(opts SnapshotOptions) Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
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

func (s *emulatorScreen) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	s.available = false
	if s.closeFn != nil {
		return s.closeFn()
	}
	return nil
}

func (s *emulatorScreen) captureLocked() {
	if s.emu != nil {
		s.altOn = s.emu.IsAltScreen()
	}
	lines := cellsToLines(readCharmCells(s.emu, s.cols, s.rows))
	if s.altOn {
		s.alternate = lines
	} else {
		s.primary = lines
	}
}

func (s *emulatorScreen) markUnavailableLocked(kind string, detail any) {
	s.available = false
	logFailure(s.logger, s.name, kind, detail, s.failLogInterval, &s.lastFailLog)
}

func logFailure(logger *log.Logger, name, kind string, detail any, interval time.Duration, last *time.Time) {
	if logger == nil || last == nil {
		return
	}
	now := time.Now()
	if interval > 0 && !last.IsZero() && now.Sub(*last) < interval {
		return
	}
	*last = now
	if name != "" {
		logger.Printf("vtscreen %s: model unavailable: %s: %v", name, kind, detail)
		return
	}
	logger.Printf("vtscreen: model unavailable: %s: %v", kind, detail)
}

type cell struct {
	content string
	width   int
}

func resizeLines(src []string, rows int) []string {
	out := make([]string, rows)
	copy(out, src)
	return out
}

func cellsToLines(grid [][]cell) []string {
	lines := make([]string, len(grid))
	for y, row := range grid {
		var b strings.Builder
		for _, c := range row {
			if c.width == 0 {
				continue
			}
			if c.content == "" {
				b.WriteByte(' ')
				continue
			}
			b.WriteString(c.content)
		}
		lines[y] = strings.TrimRight(b.String(), " ")
	}
	return lines
}

func readCharmCells(emu *xvt.Emulator, cols, rows int) [][]cell {
	if emu != nil {
		cols, rows = emu.Width(), emu.Height()
	}
	grid := make([][]cell, rows)
	for y := 0; y < rows; y++ {
		row := make([]cell, 0, cols)
		for x := 0; x < cols; {
			if emu == nil {
				row = append(row, cell{content: " ", width: 1})
				x++
				continue
			}
			c := emu.CellAt(x, y)
			if c == nil {
				row = append(row, cell{content: " ", width: 1})
				x++
				continue
			}
			w := c.Width
			if w == 0 {
				if c.Content != "" && len(row) > 0 {
					row[len(row)-1].content += c.Content
				}
				x++
				continue
			}
			if w < 1 {
				w = 1
			}
			row = append(row, cell{content: c.Content, width: w})
			x += w
		}
		grid[y] = row
	}
	return grid
}

func splitAltTransitions(p []byte) [][]byte {
	if len(p) == 0 {
		return nil
	}
	var out [][]byte
	start := 0
	for i := 0; i < len(p); {
		if n := altScreenSeqLen(p[i:]); n > 0 {
			if i > start {
				out = append(out, p[start:i])
			}
			out = append(out, p[i:i+n])
			i += n
			start = i
			continue
		}
		i++
	}
	if start < len(p) {
		out = append(out, p[start:])
	}
	return out
}

func altScreenSeqLen(p []byte) int {
	if len(p) < 5 || p[0] != 0x1b || p[1] != '[' || p[2] != '?' {
		return 0
	}
	i := 3
	for i < len(p) && (p[i] == ';' || p[i] >= '0' && p[i] <= '9') {
		i++
	}
	if i >= len(p) || (p[i] != 'h' && p[i] != 'l') {
		return 0
	}
	for _, part := range strings.Split(string(p[3:i]), ";") {
		if part == "47" || part == "1047" || part == "1049" {
			return i + 1
		}
	}
	return 0
}
