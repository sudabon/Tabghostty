package session

import (
	"bytes"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type recordScreen struct {
	mu      sync.Mutex
	feeds   [][]byte
	cols    int
	rows    int
	closed  bool
	fedAt   []time.Time
	feedErr error
}

func (r *recordScreen) Feed(data []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return vtscreen.ErrUnavailable
	}
	if r.feedErr != nil {
		return r.feedErr
	}
	r.feeds = append(r.feeds, bytes.Clone(data))
	r.fedAt = append(r.fedAt, time.Now())
	return nil
}

func (r *recordScreen) Resize(cols, rows int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return vtscreen.ErrUnavailable
	}
	r.cols, r.rows = cols, rows
	return nil
}

func (r *recordScreen) Snapshot(opts vtscreen.SnapshotOptions) vtscreen.Snapshot {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return vtscreen.Snapshot{Available: false}
	}
	return vtscreen.Snapshot{Available: true, Cols: r.cols, Rows: r.rows, Buffer: opts.Buffer}
}

func (r *recordScreen) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	return nil
}

type mutatingScreen struct {
	recordScreen
}

func (m *mutatingScreen) Feed(data []byte) error {
	for i := range data {
		data[i] = 'X'
	}
	return m.recordScreen.Feed(data)
}

func TestCreateKeepsSessionWhenScreenFactoryFails(t *testing.T) {
	s, err := Create(CreateOpts{
		Shell:         "/bin/sh",
		Cwd:           t.TempDir(),
		Cols:          80,
		Rows:          24,
		ScreenFactory: func(int, int) (vtscreen.Screen, error) { return nil, errors.New("boom") },
	})
	if err != nil {
		t.Fatalf("Create err = %v, want session to start", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if s.ScreenSnapshot(vtscreen.SnapshotOptions{Lines: 1}).Available {
		t.Fatal("snapshot available after factory failure")
	}
}

func TestReadLoopFeedsScreenBeforeOutputCallback(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	rec := &recordScreen{cols: 20, rows: 4}
	var outputAt time.Time
	s := &Session{
		pty:    reader,
		Ring:   NewRingBuffer(1024),
		screen: rec,
		onOutput: func(*Session, []byte) {
			outputAt = time.Now()
		},
	}
	go func() {
		_, _ = writer.Write([]byte("abc"))
		_ = writer.Close()
	}()
	s.readLoop()

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.feeds) == 0 || !bytes.Equal(rec.feeds[0], []byte("abc")) {
		t.Fatalf("feeds = %#v, want abc before callback", rec.feeds)
	}
	if outputAt.Before(rec.fedAt[0]) {
		t.Fatal("onOutput ran before screen Feed")
	}
}

func TestReadLoopPreservesBytesWhenScreenMutatesChunk(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	want := []byte("hello\x1b]9;note\x07world")
	var outputs []byte
	var events []osc.Event
	s := &Session{
		pty:    reader,
		Ring:   NewRingBuffer(1024),
		screen: &mutatingScreen{},
		onOutput: func(_ *Session, data []byte) {
			outputs = append(outputs, data...)
		},
		onEvent: func(_ *Session, ev osc.Event) {
			events = append(events, ev)
		},
	}
	go func() {
		_, _ = writer.Write(want)
		_ = writer.Close()
	}()
	s.readLoop()

	if !bytes.Equal(s.Ring.Bytes(), want) {
		t.Fatalf("ring = %q, want %q", s.Ring.Bytes(), want)
	}
	if !bytes.Equal(outputs, want) {
		t.Fatalf("onOutput = %q, want %q", outputs, want)
	}
	if len(events) != 1 || events[0].Kind != osc.EventNotify || events[0].Body != "note" {
		t.Fatalf("events = %#v, want OSC notify", events)
	}
}

func TestReadLoopReconstructsPrimaryWithoutClient(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	scr, err := vtscreen.New(20, 4)
	if err != nil {
		t.Fatal(err)
	}
	s := &Session{pty: reader, Ring: NewRingBuffer(4096), screen: scr, Cols: 20, Rows: 4}
	go func() {
		_, _ = writer.Write([]byte("\x1b[H\x1b[2Jhello world\x1b[1;7HXXX"))
		_ = writer.Close()
	}()
	s.readLoop()

	snap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: 4})
	if !snap.Available || snap.Lines[0] != "hello XXXld" {
		t.Fatalf("snapshot = %+v, want primary hello XXXld", snap)
	}
}

func TestReadLoopRestoresAlternateScreen(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	scr, err := vtscreen.New(16, 3)
	if err != nil {
		t.Fatal(err)
	}
	s := &Session{pty: reader, Ring: NewRingBuffer(4096), screen: scr}
	go func() {
		_, _ = writer.Write([]byte("\x1b[H\x1b[2JPRIMARY\x1b[?1049h\x1b[H\x1b[2JALT"))
		_ = writer.Close()
	}()
	s.readLoop()

	active := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: 3})
	if active.Active != vtscreen.BufferAlternate || active.Lines[0] != "ALT" {
		t.Fatalf("active = %+v", active)
	}
	primary := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferPrimary, Lines: 3})
	if primary.Lines[0] != "PRIMARY" {
		t.Fatalf("primary = %+v", primary)
	}
}

func TestReadLoopNormalizesJapaneseGlyphs(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	scr, err := vtscreen.New(12, 2)
	if err != nil {
		t.Fatal(err)
	}
	s := &Session{pty: reader, Ring: NewRingBuffer(4096), screen: scr}
	go func() {
		_, _ = writer.Write([]byte("\x1b[H\x1b[2J日本語\x1b[1;7HX"))
		_ = writer.Close()
	}()
	s.readLoop()

	snap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: 2})
	if snap.Lines[0] != "日本語X" {
		t.Fatalf("line = %q, want 日本語X", snap.Lines[0])
	}
}

func TestResizeFailureDoesNotClaimGeometry(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = writer.Close() })
	scr, err := vtscreen.New(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	s := &Session{pty: reader, screen: scr, Cols: 80, Rows: 24}
	if err := s.Resize(160, 50); err == nil {
		t.Fatal("expected pipe resize to fail")
	}
	if s.Cols != 80 || s.Rows != 24 {
		t.Fatalf("size = %dx%d, want 80x24", s.Cols, s.Rows)
	}
	snap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Lines: 24})
	if snap.Cols != 80 || snap.Rows != 24 {
		t.Fatalf("screen geometry = %dx%d, want 80x24", snap.Cols, snap.Rows)
	}
}

func TestAcceptedResizeUpdatesScreen(t *testing.T) {
	s, err := Create(CreateOpts{Shell: "/bin/sh", Cwd: t.TempDir(), Cols: 80, Rows: 24})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Resize(40, 10); err != nil {
		t.Fatal(err)
	}
	if s.Cols != 40 || s.Rows != 10 {
		t.Fatalf("session size = %dx%d, want 40x10", s.Cols, s.Rows)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		snap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Lines: 10})
		if snap.Available && snap.Cols == 40 && snap.Rows == 10 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	snap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Lines: 10})
	t.Fatalf("screen snapshot = %+v, want 40x10", snap)
}

func TestCloseMakesScreenUnavailable(t *testing.T) {
	rec := &recordScreen{cols: 8, rows: 2}
	s := &Session{screen: rec, done: make(chan struct{})}
	close(s.done)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if !rec.closed {
		t.Fatal("screen not closed")
	}
	if s.ScreenSnapshot(vtscreen.SnapshotOptions{Lines: 1}).Available {
		t.Fatal("snapshot available after close")
	}
}

func TestReadLoopDoesNotStallOnTerminalQueries(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	scr, err := vtscreen.New(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = scr.Close() })
	want := []byte("\x1b[c\x1b[6nhello")
	var outputs []byte
	s := &Session{
		pty:    reader,
		Ring:   NewRingBuffer(1024),
		screen: scr,
		onOutput: func(_ *Session, data []byte) {
			outputs = append(outputs, data...)
		},
	}
	go func() {
		_, _ = writer.Write(want)
		_ = writer.Close()
	}()
	done := make(chan struct{})
	go func() {
		s.readLoop()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("readLoop stalled on DA1/DSR; output %q", outputs)
	}
	if !bytes.Equal(s.Ring.Bytes(), want) {
		t.Fatalf("ring = %q, want %q", s.Ring.Bytes(), want)
	}
	if !bytes.Equal(outputs, want) {
		t.Fatalf("onOutput = %q, want %q", outputs, want)
	}
}

func TestScreenFeedFailureDoesNotStopForwarding(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	rec := &recordScreen{feedErr: errors.New("bad seq")}
	var outputs []byte
	s := &Session{
		pty:    reader,
		Ring:   NewRingBuffer(1024),
		screen: rec,
		onOutput: func(_ *Session, data []byte) {
			outputs = append(outputs, data...)
		},
	}
	go func() {
		_, _ = writer.Write([]byte("keep-going"))
		_ = writer.Close()
	}()
	s.readLoop()
	if !bytes.Equal(s.Ring.Bytes(), []byte("keep-going")) {
		t.Fatalf("ring = %q", s.Ring.Bytes())
	}
	if !bytes.Equal(outputs, []byte("keep-going")) {
		t.Fatalf("output = %q", outputs)
	}
}

func TestModeledStreamPreservesByteIdentity(t *testing.T) {
	if testing.Short() {
		t.Skip("100 MiB identity")
	}
	const size = 100 * 1024 * 1024
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	scr, err := vtscreen.New(80, 24)
	if err != nil {
		t.Fatal(err)
	}
	var outputs []byte
	s := &Session{
		pty:    reader,
		Ring:   NewRingBuffer(size),
		screen: scr,
		onOutput: func(_ *Session, data []byte) {
			outputs = append(outputs, data...)
		},
	}
	want := deterministicStream(size)
	go func() {
		_, _ = writer.Write(want)
		_ = writer.Close()
	}()
	s.readLoop()
	if !bytes.Equal(s.Ring.Bytes(), want) {
		t.Fatal("ring bytes diverged from input")
	}
	if !bytes.Equal(outputs, want) {
		t.Fatal("onOutput bytes diverged from input")
	}
}

func deterministicStream(n int) []byte {
	out := make([]byte, n)
	for i := range out {
		switch i % 17 {
		case 0:
			out[i] = 'A' + byte(i%26)
		case 1:
			out[i] = '\n'
		default:
			out[i] = 'a' + byte(i%26)
		}
	}
	return out
}

func TestCreateInitialSnapshotGeometry(t *testing.T) {
	s, err := Create(CreateOpts{Shell: "/bin/sh", Cwd: t.TempDir(), Cols: 120, Rows: 40})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	snap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Lines: 40})
	if !snap.Available || snap.Cols != 120 || snap.Rows != 40 {
		t.Fatalf("snapshot = %+v, want 120x40", snap)
	}
}

func TestReadLoopContinuesWhenScreenIsNil(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	var outputs []byte
	s := &Session{
		pty:  reader,
		Ring: NewRingBuffer(64),
		onOutput: func(_ *Session, data []byte) {
			outputs = append(outputs, data...)
		},
	}
	go func() {
		_, _ = writer.Write([]byte("ok"))
		_ = writer.Close()
	}()
	s.readLoop()
	if string(outputs) != "ok" {
		t.Fatalf("output = %q", outputs)
	}
}

func BenchmarkModeledVersusUnmodeled(b *testing.B) {
	payload := deterministicStream(100 * 1024 * 1024)
	b.Run("unmodeled", func(b *testing.B) {
		benchmarkReadLoop(b, payload, nil)
	})
	b.Run("modeled", func(b *testing.B) {
		benchmarkReadLoop(b, payload, func() vtscreen.Screen {
			s, err := vtscreen.New(80, 24)
			if err != nil {
				b.Fatal(err)
			}
			return s
		})
	})
}

func benchmarkReadLoop(b *testing.B, payload []byte, factory func() vtscreen.Screen) {
	b.Helper()
	b.SetBytes(int64(len(payload)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		reader, writer, err := os.Pipe()
		if err != nil {
			b.Fatal(err)
		}
		var scr vtscreen.Screen
		if factory != nil {
			scr = factory()
		}
		s := &Session{pty: reader, Ring: NewRingBuffer(len(payload)), screen: scr, onOutput: func(*Session, []byte) {}}
		b.StartTimer()
		go func() {
			_, _ = writer.Write(payload)
			_ = writer.Close()
		}()
		s.readLoop()
		if scr != nil {
			_ = scr.Close()
		}
	}
}
