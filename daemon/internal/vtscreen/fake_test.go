package vtscreen

import (
	"strings"
	"sync"
	"unicode/utf8"
)

// fakeScreen is a contract-only model: printable text, CR/LF, and DECSET 1049.
type fakeScreen struct {
	mu        sync.Mutex
	cols      int
	rows      int
	primary   [][]rune
	alternate [][]rune
	altOn     bool
	curX      int
	curY      int
	available bool
	closed    bool
}

func newFake(cols, rows int) (Screen, error) {
	if cols <= 0 || rows <= 0 {
		return nil, ErrUnavailable
	}
	s := &fakeScreen{
		cols:      cols,
		rows:      rows,
		primary:   blankGrid(cols, rows),
		alternate: blankGrid(cols, rows),
		available: true,
	}
	return s, nil
}

func blankGrid(cols, rows int) [][]rune {
	g := make([][]rune, rows)
	for y := range g {
		g[y] = blankRow(cols)
	}
	return g
}

func blankRow(cols int) []rune {
	row := make([]rune, cols)
	for i := range row {
		row[i] = ' '
	}
	return row
}

func (s *fakeScreen) Feed(data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
		return ErrUnavailable
	}
	i := 0
	for i < len(data) {
		if data[i] == 0x1b && i+1 < len(data) && data[i+1] == '[' {
			n, ok := s.consumeCSI(data[i:])
			if ok {
				i += n
				continue
			}
		}
		r, size := utf8.DecodeRune(data[i:])
		if r == utf8.RuneError && size == 1 {
			i++
			continue
		}
		s.putRune(r)
		i += size
	}
	return nil
}

func (s *fakeScreen) consumeCSI(data []byte) (int, bool) {
	if len(data) < 4 || data[0] != 0x1b || data[1] != '[' {
		return 0, false
	}
	if strings.HasPrefix(string(data), "\x1b[?1049h") {
		s.altOn = true
		s.curX, s.curY = 0, 0
		return 8, true
	}
	if strings.HasPrefix(string(data), "\x1b[?1049l") {
		s.altOn = false
		s.curX, s.curY = 0, 0
		return 8, true
	}
	end := 2
	for end < len(data) && (data[end] < 0x40 || data[end] > 0x7e) {
		end++
	}
	if end >= len(data) {
		return 0, false
	}
	return end + 1, true
}

func (s *fakeScreen) putRune(r rune) {
	switch r {
	case '\n':
		s.curX = 0
		if s.curY+1 < s.rows {
			s.curY++
		}
		return
	case '\r':
		s.curX = 0
		return
	case '\b':
		if s.curX > 0 {
			s.curX--
		}
		return
	}
	if r < 0x20 {
		return
	}
	grid := s.activeGrid()
	if s.curY < 0 || s.curY >= len(grid) || s.curX < 0 || s.curX >= s.cols {
		return
	}
	grid[s.curY][s.curX] = r
	if s.curX+1 < s.cols {
		s.curX++
	}
}

func (s *fakeScreen) activeGrid() [][]rune {
	if s.altOn {
		return s.alternate
	}
	return s.primary
}

func (s *fakeScreen) Resize(cols, rows int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || !s.available {
		return ErrUnavailable
	}
	if cols <= 0 || rows <= 0 {
		s.available = false
		return ErrUnavailable
	}
	s.primary = resizeGrid(s.primary, cols, rows)
	s.alternate = resizeGrid(s.alternate, cols, rows)
	s.cols, s.rows = cols, rows
	if s.curX >= cols {
		s.curX = cols - 1
	}
	if s.curY >= rows {
		s.curY = rows - 1
	}
	return nil
}

func resizeGrid(src [][]rune, cols, rows int) [][]rune {
	out := blankGrid(cols, rows)
	for y := 0; y < rows && y < len(src); y++ {
		copy(out[y], src[y])
	}
	return out
}

func (s *fakeScreen) Snapshot(opts SnapshotOptions) Snapshot {
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
	grid := s.primary
	switch kind {
	case BufferAlternate:
		grid = s.alternate
	case BufferActive:
		resolved = active
		grid = s.activeGrid()
	default:
		grid = s.primary
		resolved = BufferPrimary
	}
	lines := make([]string, len(grid))
	for i, row := range grid {
		lines[i] = strings.TrimRight(string(row), " ")
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

func (s *fakeScreen) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	s.available = false
	return nil
}
