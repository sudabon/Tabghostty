package session

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/creack/pty"
	"github.com/google/uuid"
	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/integration"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/paths"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type State string

const (
	StateStarting State = "starting"
	StateIdle     State = "idle"
	StateRunning  State = "running"
	StateExited   State = "exited"
)

type Session struct {
	ID         string
	Order      int
	Cwd        string
	Command    string
	State      State
	ExitCode   *int
	RunStarted time.Time
	LastRunMs  int64
	Ring       *RingBuffer
	Integrated bool
	Memo       string
	// NotificationsMuted silences desktop banners for this session only; the
	// zero value keeps notifications on.
	NotificationsMuted bool
	Cols               uint16
	Rows               uint16
	// ShellExited records that the shell announced its own termination via the
	// private OSC exit signal. `exit` and Ctrl+D return the last command's
	// status, so the signal — not the status — tells us the user asked to quit.
	ShellExited bool
	// PromptSeen records that the shell reached its first prompt, i.e. it got
	// far enough to be interactive rather than dying inside its startup files.
	PromptSeen bool

	mu         sync.Mutex
	pty        *os.File
	cmd        *exec.Cmd
	parser     osc.Parser
	onEvent    func(*Session, osc.Event)
	onExit     func(*Session)
	onOutput   func(*Session, []byte)
	logger     *log.Logger
	done       chan struct{}
	readDone   chan struct{}
	readClosed bool
	closed     bool
	screen     vtscreen.Screen

	// drainWait bounds how long waitLoop waits for readLoop to finish. Tests
	// shorten it; zero means drainTimeout.
	drainWait time.Duration

	colorQueries map[int]int
	palette      osc.Palette
}

type Info struct {
	ID                 string `json:"id"`
	Order              int    `json:"order"`
	Cwd                string `json:"cwd"`
	Command            string `json:"command"`
	State              State  `json:"state"`
	ExitCode           *int   `json:"exit"`
	Integrated         bool   `json:"integrated"`
	ShellExited        bool   `json:"shell_exited"`
	PromptSeen         bool   `json:"prompt_seen"`
	Memo               string `json:"memo"`
	NotificationsMuted bool   `json:"notifications_muted"`
	RunMs              int64  `json:"run_ms,omitempty"`
	Agent              string `json:"agent"`
	AgentState         string `json:"agent_state"`
	AgentStateSince    string `json:"agent_state_since"`
	AgentStateSignal   string `json:"agent_state_signal"`
	AgentStateDetail   string `json:"agent_state_detail,omitempty"`
}

const MaxMemoRunes = 30

// drainTimeout bounds the wait for readLoop to drain the PTY after the shell
// process is reaped. The shell-exit signal arrives as the very last bytes
// before termination, so onExit must not run before it is parsed. A child
// process still holding the PTY slave keeps readLoop alive indefinitely, hence
// the ceiling; exceeding it only costs us the signal, falling back to the
// exit-status rule.
const drainTimeout = 300 * time.Millisecond

func (s *Session) Info() Info {
	s.mu.Lock()
	defer s.mu.Unlock()
	info := Info{
		ID:                 s.ID,
		Order:              s.Order,
		Cwd:                s.Cwd,
		Command:            s.Command,
		State:              s.State,
		ExitCode:           s.ExitCode,
		Integrated:         s.Integrated,
		ShellExited:        s.ShellExited,
		PromptSeen:         s.PromptSeen,
		Memo:               s.Memo,
		NotificationsMuted: s.NotificationsMuted,
		RunMs:              s.LastRunMs,
		AgentState:         string(agentdetect.StateNone),
	}
	if s.State == StateRunning && !s.RunStarted.IsZero() {
		info.RunMs = time.Since(s.RunStarted).Milliseconds()
	}
	return info
}

// SetMemo trims and stores memo. Values longer than MaxMemoRunes Unicode code points are rejected.
func (s *Session) SetMemo(memo string) error {
	return s.Patch(&memo, nil)
}

// Patch updates the provided fields together. The memo is validated first, so
// a rejected memo leaves every field unchanged.
func (s *Session) Patch(memo *string, notificationsMuted *bool) error {
	var trimmed string
	if memo != nil {
		trimmed = strings.TrimSpace(*memo)
		if utf8.RuneCountInString(trimmed) > MaxMemoRunes {
			return fmt.Errorf("memo exceeds %d characters", MaxMemoRunes)
		}
	}
	s.mu.Lock()
	if memo != nil {
		s.Memo = trimmed
	}
	if notificationsMuted != nil {
		s.NotificationsMuted = *notificationsMuted
	}
	s.mu.Unlock()
	return nil
}

type CreateOpts struct {
	Shell           string
	Cwd             string
	RingBufferBytes int
	Cols            uint16
	Rows            uint16
	OnEvent         func(*Session, osc.Event)
	OnExit          func(*Session)
	OnOutput        func(*Session, []byte)
	Logger          *log.Logger
	Palette         osc.Palette
	ScreenFactory   vtscreen.Factory
}

func Create(opts CreateOpts) (*Session, error) {
	if opts.Shell == "" {
		opts.Shell = "/bin/zsh"
	}
	if opts.Cwd == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		opts.Cwd = home
	}
	if opts.Cols == 0 {
		opts.Cols = 120
	}
	if opts.Rows == 0 {
		opts.Rows = 40
	}

	if opts.Palette.Name == "" {
		opts.Palette = osc.DarkPalette()
	}

	id := uuid.NewString()
	env := shellEnv(id, opts.Palette)
	injected, err := integration.ApplyZshInjection(env, opts.Shell)
	if err != nil {
		if opts.Logger != nil {
			opts.Logger.Printf("zsh integration inject: %v", err)
		}
	} else {
		env = injected
	}
	injected, err = integration.ApplyBashInjection(env, opts.Shell)
	if err != nil {
		if opts.Logger != nil {
			opts.Logger.Printf("bash integration inject: %v", err)
		}
	} else {
		env = injected
	}
	cmd := exec.Command(opts.Shell, shellArgs(opts.Shell)...)
	cmd.Dir = opts.Cwd
	cmd.Env = env

	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: opts.Cols, Rows: opts.Rows})
	if err != nil {
		return nil, err
	}

	s := &Session{
		ID:       id,
		Cwd:      opts.Cwd,
		Command:  filepath.Base(opts.Shell),
		State:    StateStarting,
		Ring:     NewRingBuffer(opts.RingBufferBytes),
		Cols:     opts.Cols,
		Rows:     opts.Rows,
		pty:      ptmx,
		cmd:      cmd,
		onEvent:  opts.OnEvent,
		onExit:   opts.OnExit,
		onOutput: opts.OnOutput,
		logger:   opts.Logger,
		done:     make(chan struct{}),
		readDone: make(chan struct{}),
		palette:  opts.Palette,
		screen:   openScreen(opts.ScreenFactory, int(opts.Cols), int(opts.Rows), opts.Logger, id),
	}

	go s.readLoop()
	go s.waitLoop()
	return s, nil
}

func openScreen(factory vtscreen.Factory, cols, rows int, logger *log.Logger, id string) vtscreen.Screen {
	defer func() {
		if rec := recover(); rec != nil && logger != nil {
			logger.Printf("session %s screen model: panic: %v", id, rec)
		}
	}()
	if factory == nil {
		factory = func(c, r int) (vtscreen.Screen, error) {
			return vtscreen.Open(vtscreen.Options{Cols: c, Rows: r, Logger: logger, Name: id})
		}
	}
	scr, err := factory(cols, rows)
	if err != nil {
		if logger != nil {
			logger.Printf("session %s screen model: %v", id, err)
		}
		return nil
	}
	return scr
}

func shellArgs(shell string) []string {
	if filepath.Base(shell) == "bash" {
		if rc, err := paths.BashRcfile(); err == nil {
			// bash 3.2 requires GNU long options before short options.
			return []string{"--rcfile", rc, "-i"}
		}
	}
	return []string{"-il"}
}

func (s *Session) readLoop() {
	defer s.closeReadDone()
	buf := make([]byte, 32*1024)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.Ring.Write(chunk)
			events := s.parser.Feed(chunk)
			s.handleEvents(events)
			s.feedScreen(chunk)
			if s.onOutput != nil {
				s.onOutput(s, chunk)
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && s.logger != nil {
				s.logger.Printf("session %s pty read: %v", s.ID, err)
			}
			return
		}
	}
}

func (s *Session) waitLoop() {
	err := s.cmd.Wait()
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			code = 1
		}
	}
	// Close done first so Close() stays responsive, then let readLoop finish
	// parsing the shell's final output. applyEvent ignores events once the
	// state is exited, so the state must be settled only after the drain.
	close(s.done)
	s.drainReads()
	s.mu.Lock()
	s.State = StateExited
	s.ExitCode = &code
	s.mu.Unlock()
	if s.onExit != nil {
		s.onExit(s)
	}
}

// drainReads waits, up to a bound, for readLoop to consume the output the
// shell produced just before it died.
func (s *Session) drainReads() {
	s.mu.Lock()
	readDone := s.readDone
	wait := s.drainWait
	s.mu.Unlock()
	if readDone == nil {
		return
	}
	if wait <= 0 {
		wait = drainTimeout
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-readDone:
	case <-timer.C:
	}
}

func (s *Session) closeReadDone() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.readDone == nil || s.readClosed {
		return
	}
	s.readClosed = true
	close(s.readDone)
}

func (s *Session) handleEvents(events []osc.Event) {
	for _, ev := range events {
		if ev.Kind == osc.EventColorQuery {
			s.replyColorQueries(ev.ColorIndexes)
			continue
		}
		s.applyEvent(ev)
		if s.onEvent != nil {
			s.onEvent(s, ev)
		}
	}
}

func (s *Session) replyColorQueries(ids []int) {
	report := s.palette.Reports(ids)
	if len(report) == 0 {
		return
	}
	s.mu.Lock()
	ptmx := s.pty
	closed := s.closed
	s.mu.Unlock()
	if closed || ptmx == nil {
		return
	}
	_, _ = ptmx.Write(report)
}

func shellEnv(id string, p osc.Palette) []string {
	env := append(dropForeignShellHooks(os.Environ()),
		fmt.Sprintf("WEBTABINAL_SESSION_ID=%s", id),
		"TERM=xterm-256color",
	)
	return withLocaleEnv(mergeThemeEnv(env, p), detectUTF8Locale())
}

// dropForeignShellHooks removes shell-integration hooks inherited from the
// terminal that started the daemon. PROMPT_COMMAND is not normally exported,
// so an environment entry means some other terminal's integration exported it;
// the function it names is never defined inside a WebTabinal session, and our
// bash integration would faithfully invoke it on every prompt. A PROMPT_COMMAND
// the user's own startup files set is unaffected, because it is established
// after the session shell starts.
func dropForeignShellHooks(env []string) []string {
	out := make([]string, 0, len(env))
	for _, e := range env {
		if key, _, _ := strings.Cut(e, "="); key == "PROMPT_COMMAND" {
			continue
		}
		out = append(out, e)
	}
	return out
}

func mergeThemeEnv(env []string, p osc.Palette) []string {
	skip := map[string]bool{
		"TERM_THEME": true,
		"ANSI_LIGHT": true,
		"COLORFGBG":  true,
	}
	out := make([]string, 0, len(env)+3)
	for _, e := range env {
		key, _, _ := strings.Cut(e, "=")
		if skip[key] {
			continue
		}
		out = append(out, e)
	}
	return append(out, p.Env()...)
}

func (s *Session) applyEvent(ev osc.Event) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.State == StateExited {
		return
	}
	switch ev.Kind {
	case osc.EventCWD:
		s.Cwd = ev.CWD
		s.Integrated = true
		if s.State == StateStarting {
			s.State = StateIdle
		}
	case osc.EventCmdStart:
		if ev.Command != "" {
			s.Command = ev.Command
		}
		if isUserShellExitCommand(ev.Command) {
			s.ShellExited = true
		}
		s.State = StateRunning
		s.RunStarted = time.Now()
		s.ExitCode = nil
	case osc.EventCmdEnd:
		if s.State == StateRunning && !s.RunStarted.IsZero() {
			s.LastRunMs = time.Since(s.RunStarted).Milliseconds()
		}
		s.State = StateIdle
		s.ExitCode = ev.ExitCode
	case osc.EventPrompt:
		s.PromptSeen = true
		if s.State == StateStarting {
			s.State = StateIdle
		}
		if s.State == StateRunning {
			if !s.RunStarted.IsZero() {
				s.LastRunMs = time.Since(s.RunStarted).Milliseconds()
			}
			s.State = StateIdle
		}
	case osc.EventShellExit:
		// Deliberately touches nothing else: the shell is on its way out, and
		// the tab-close decision is the only consumer of this flag.
		s.ShellExited = true
	}
}

// isUserShellExitCommand reports whether cmd is the shell terminating itself
// (`exit`, `logout`, optionally via `builtin`). The DEBUG/preexec OSC carries
// this before the process is reaped, so it is available even when the later
// EXIT/zshexit signal never arrives.
func isUserShellExitCommand(cmd string) bool {
	cmd = strings.TrimSpace(cmd)
	switch cmd {
	case "exit", "logout", "builtin exit", "builtin logout":
		return true
	}
	for _, prefix := range []string{"exit ", "logout ", "builtin exit ", "builtin logout "} {
		if strings.HasPrefix(cmd, prefix) {
			return true
		}
	}
	return false
}

func (s *Session) Write(data []byte) error {
	filtered := osc.FilterColorReports(data, s.consumeColorQuery)
	if len(filtered) == 0 {
		return nil
	}
	s.mu.Lock()
	ptmx := s.pty
	closed := s.closed
	s.mu.Unlock()
	if closed || ptmx == nil {
		return io.ErrClosedPipe
	}
	_, err := ptmx.Write(filtered)
	return err
}

func (s *Session) consumeColorQuery(code int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := s.colorQueries[code]
	if n <= 0 {
		return false
	}
	if n == 1 {
		delete(s.colorQueries, code)
	} else {
		s.colorQueries[code] = n - 1
	}
	return true
}

func (s *Session) feedScreen(chunk []byte) {
	s.mu.Lock()
	scr := s.screen
	s.mu.Unlock()
	if scr == nil {
		return
	}
	_ = scr.Feed(bytes.Clone(chunk))
}

func (s *Session) ScreenSnapshot(opts vtscreen.SnapshotOptions) vtscreen.Snapshot {
	s.mu.Lock()
	scr := s.screen
	s.mu.Unlock()
	if scr == nil {
		return vtscreen.Snapshot{Available: false}
	}
	return scr.Snapshot(opts)
}

// MarkScreenUnavailable closes the VT model so diagnostics return a structured 409.
func (s *Session) MarkScreenUnavailable() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.screen != nil {
		_ = s.screen.Close()
		s.screen = nil
	}
}

func (s *Session) Resize(cols, rows uint16) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return io.ErrClosedPipe
	}
	if s.pty != nil {
		if err := pty.Setsize(s.pty, &pty.Winsize{Cols: cols, Rows: rows}); err != nil {
			return err
		}
	}
	s.Cols, s.Rows = cols, rows
	if s.screen != nil {
		_ = s.screen.Resize(int(cols), int(rows))
	}
	return nil
}

func (s *Session) SetFallbackState(running bool, cmdName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Integrated || s.State == StateExited || s.State == StateStarting {
		return
	}
	if running {
		if s.State != StateRunning {
			s.RunStarted = time.Now()
		}
		s.State = StateRunning
		if cmdName != "" {
			s.Command = cmdName
		}
	} else {
		if s.State == StateRunning && !s.RunStarted.IsZero() {
			s.LastRunMs = time.Since(s.RunStarted).Milliseconds()
		}
		s.State = StateIdle
	}
}

// SetRemoteState applies the screen-derived verdict for a session whose
// foreground is a login client. Unlike SetFallbackState it also runs on
// integrated sessions, because the local integration is precisely what
// reported `running` when `ssh` started and it cannot see the far side; its
// verdict is the one being corrected here.
func (s *Session) SetRemoteState(running bool, cmdName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.State == StateExited || s.State == StateStarting {
		return
	}
	if running {
		if s.State != StateRunning {
			s.RunStarted = time.Now()
		}
		s.State = StateRunning
	} else {
		if s.State == StateRunning && !s.RunStarted.IsZero() {
			s.LastRunMs = time.Since(s.RunStarted).Milliseconds()
		}
		s.State = StateIdle
	}
	// An integrated session already holds the full command line ("ssh host"),
	// which beats the bare executable name; only a non-integrated one needs
	// this filled in.
	if cmdName != "" && s.Command == "" {
		s.Command = cmdName
	}
}

func (s *Session) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	cmd := s.cmd
	ptmx := s.pty
	scr := s.screen
	s.mu.Unlock()

	if scr != nil {
		_ = scr.Close()
	}

	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Signal(syscall.SIGHUP)
		select {
		case <-s.done:
		case <-time.After(3 * time.Second):
			_ = cmd.Process.Kill()
		}
	}
	if ptmx != nil {
		_ = ptmx.Close()
	}
	return nil
}

func (s *Session) PTY() *os.File {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pty
}

func (s *Session) CmdProcessPID() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd == nil || s.cmd.Process == nil {
		return 0
	}
	return s.cmd.Process.Pid
}
