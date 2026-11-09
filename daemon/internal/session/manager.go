package session

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

var (
	ErrNotFound          = errors.New("session not found")
	ErrScreenUnavailable = errors.New("screen model is unavailable")
)

type Manager struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	order    []string
	cfg      *config.Store
	logger   *log.Logger
	onChange func()
	onOutput func(*Session, []byte)
	onEvent  func(*Session, osc.Event)
	onExit   func(*Session)
	onDrop   func(string)
	stopFB   chan struct{}
	engine   *agentdetect.Engine
}

func NewManager(cfg *config.Store, logger *log.Logger) *Manager {
	m := &Manager{
		sessions: make(map[string]*Session),
		cfg:      cfg,
		logger:   logger,
		stopFB:   make(chan struct{}),
		engine:   newAgentEngine(cfg, logger),
	}
	go m.fallbackLoop()
	return m
}

func (m *Manager) SetHooks(onChange func(), onOutput func(*Session, []byte), onEvent func(*Session, osc.Event), onExit func(*Session)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.onChange = onChange
	m.onOutput = onOutput
	m.onEvent = onEvent
	m.onExit = onExit
}

func (m *Manager) SetOnDrop(fn func(string)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.onDrop = fn
}

func (m *Manager) hooks() (func(), func(*Session, []byte), func(*Session, osc.Event), func(*Session)) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.onChange, m.onOutput, m.onEvent, m.onExit
}

func (m *Manager) Close() {
	close(m.stopFB)
	m.mu.Lock()
	list := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		list = append(list, s)
	}
	eng := m.engine
	m.mu.Unlock()
	for _, s := range list {
		if eng != nil {
			eng.Close(s.ID)
		}
		_ = s.Close()
	}
}

func (m *Manager) List() []Info {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]Info, 0, len(m.order))
	for _, id := range m.order {
		if s, ok := m.sessions[id]; ok {
			out = append(out, m.enrich(s.Info()))
		}
	}
	return out
}

// SessionInfo returns the public snapshot including agent state.
func (m *Manager) SessionInfo(s *Session) Info {
	if s == nil {
		return Info{AgentState: string(agentdetect.StateNone)}
	}
	return m.enrich(s.Info())
}

func (m *Manager) enrich(info Info) Info {
	info.AgentState = string(agentdetect.StateNone)
	info.Agent = ""
	info.AgentStateSignal = ""
	info.AgentStateDetail = ""
	info.AgentStateSince = ""
	snap, ok := m.AgentSnapshot(info.ID)
	if !ok {
		return info
	}
	info.Agent = snap.AgentID
	if snap.State != "" {
		info.AgentState = string(snap.State)
	}
	if !snap.Since.IsZero() {
		info.AgentStateSince = snap.Since.UTC().Format(time.RFC3339)
	}
	info.AgentStateSignal = string(snap.Signal)
	info.AgentStateDetail = snap.Detail
	return info
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

// StateSnapshot returns a read-only diagnostic of the visible buffer and agent matches.
// It does not write to the PTY or change detector state.
func (m *Manager) StateSnapshot(id string, lines int, buffer vtscreen.BufferKind) (agentdetect.Diagnostic, error) {
	s, ok := m.Get(id)
	if !ok {
		return agentdetect.Diagnostic{}, ErrNotFound
	}
	screen := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: buffer, Lines: lines})
	if !screen.Available {
		return agentdetect.Diagnostic{}, ErrScreenUnavailable
	}
	eng := m.currentEngine()
	var agent agentdetect.Snapshot
	detectorOK := false
	var reg *agentdetect.Registry
	if eng != nil {
		reg = eng.Registry()
		agent, detectorOK = eng.Snapshot(id)
	}
	return agentdetect.BuildDiagnostic(id, screen, agent, detectorOK, reg), nil
}

func (m *Manager) Create(cwd string) (*Session, error) {
	cfg := m.cfg.Get()
	if cwd == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		cwd = home
	}
	s, err := Create(CreateOpts{
		Shell:           cfg.Shell,
		Cwd:             cwd,
		RingBufferBytes: cfg.RingBufferBytes,
		Palette:         osc.PaletteFor(cfg.ResolvedTheme()),
		Logger:          m.logger,
		OnEvent: func(sess *Session, ev osc.Event) {
			m.observeEvent(sess, ev)
			_, _, onEvent, _ := m.hooks()
			if onEvent != nil {
				onEvent(sess, ev)
			}
		},
		OnExit: func(sess *Session) {
			m.handleExit(sess)
		},
		OnOutput: func(sess *Session, data []byte) {
			m.observeOutput(sess, len(data))
			_, onOutput, _, _ := m.hooks()
			if onOutput != nil {
				onOutput(sess, data)
			}
		},
	})
	if err != nil {
		return nil, err
	}

	m.openDetector(s)

	m.mu.Lock()
	m.sessions[s.ID] = s
	m.order = append(m.order, s.ID)
	m.reindexLocked()
	onChange := m.onChange
	m.mu.Unlock()
	if onChange != nil {
		onChange()
	}
	return s, nil
}

func (m *Manager) Duplicate(id string) (*Session, error) {
	s, ok := m.Get(id)
	if !ok {
		return nil, fmt.Errorf("session not found")
	}
	info := s.Info()
	// Memo and notification mute are intentionally not copied: duplicate is a
	// separate session.
	return m.Create(info.Cwd)
}

func (m *Manager) Restart(id string) (*Session, error) {
	s, ok := m.Get(id)
	if !ok {
		return nil, fmt.Errorf("session not found")
	}
	info := s.Info()
	if info.State != StateExited {
		return nil, fmt.Errorf("session is not exited")
	}
	order := info.Order
	cwd := info.Cwd
	memo := info.Memo
	muted := info.NotificationsMuted
	ns, err := m.Create(cwd)
	if err != nil {
		return nil, err
	}
	// Memo was already validated when stored on the old session.
	_ = ns.Patch(&memo, &muted)
	m.dropDetector(id)
	_ = s.Close()

	m.mu.Lock()
	delete(m.sessions, id)
	for i, oid := range m.order {
		if oid == id {
			m.order = append(m.order[:i], m.order[i+1:]...)
			break
		}
	}
	m.mu.Unlock()

	m.mu.Lock()
	// move new session to old order position
	newOrder := make([]string, 0, len(m.order))
	inserted := false
	for _, oid := range m.order {
		if oid == ns.ID {
			continue
		}
		if !inserted && len(newOrder) == order {
			newOrder = append(newOrder, ns.ID)
			inserted = true
		}
		newOrder = append(newOrder, oid)
	}
	if !inserted {
		newOrder = append(newOrder, ns.ID)
	}
	m.order = newOrder
	m.reindexLocked()
	onChange := m.onChange
	m.mu.Unlock()
	if onChange != nil {
		onChange()
	}
	return ns, nil
}

func (m *Manager) SetMemo(id, memo string) (*Session, error) {
	return m.PatchSession(id, &memo, nil)
}

// PatchSession applies the provided fields atomically and broadcasts once.
func (m *Manager) PatchSession(id string, memo *string, notificationsMuted *bool) (*Session, error) {
	s, ok := m.Get(id)
	if !ok {
		return nil, fmt.Errorf("session not found")
	}
	if err := s.Patch(memo, notificationsMuted); err != nil {
		return nil, err
	}
	m.mu.RLock()
	onChange := m.onChange
	m.mu.RUnlock()
	if onChange != nil {
		onChange()
	}
	return s, nil
}

func (m *Manager) Delete(id string) error {
	s, ok := m.Get(id)
	if !ok {
		return fmt.Errorf("session not found")
	}
	_ = s.Close()
	m.dropDetector(id)
	m.mu.Lock()
	delete(m.sessions, id)
	for i, oid := range m.order {
		if oid == id {
			m.order = append(m.order[:i], m.order[i+1:]...)
			break
		}
	}
	m.reindexLocked()
	onChange := m.onChange
	m.mu.Unlock()
	if onChange != nil {
		onChange()
	}
	return nil
}

func (m *Manager) Reorder(ids []string) error {
	m.mu.Lock()
	if len(ids) != len(m.order) {
		m.mu.Unlock()
		return fmt.Errorf("id count mismatch")
	}
	seen := map[string]bool{}
	for _, id := range ids {
		if _, ok := m.sessions[id]; !ok {
			m.mu.Unlock()
			return fmt.Errorf("unknown session %s", id)
		}
		if seen[id] {
			m.mu.Unlock()
			return fmt.Errorf("duplicate id")
		}
		seen[id] = true
	}
	m.order = append([]string(nil), ids...)
	m.reindexLocked()
	onChange := m.onChange
	m.mu.Unlock()
	if onChange != nil {
		onChange()
	}
	return nil
}

func (m *Manager) reindexLocked() {
	for i, id := range m.order {
		if s, ok := m.sessions[id]; ok {
			s.mu.Lock()
			s.Order = i
			s.mu.Unlock()
		}
	}
}

// shouldCloseTab decides whether an exited session's tab goes away. The rules
// are evaluated in order; the first match wins.
//
//  1. auto-close disabled            -> keep
//  2. integrated but never prompted  -> keep, so startup failures stay readable
//  3. shell-exit signal recorded     -> close, whatever the status
//  4. exit status 0                  -> close (also covers unintegrated shells,
//     which never report a signal and so keep today's behaviour)
//  5. otherwise                      -> keep
//
// Rule 3 exists because `exit` and Ctrl+D return the last command's status, so
// a user-initiated exit is often non-zero.
func shouldCloseTab(info Info, closeOnCleanExit bool) bool {
	if !closeOnCleanExit {
		return false
	}
	if info.Integrated && !info.PromptSeen {
		return false
	}
	if info.ShellExited {
		return true
	}
	return info.ExitCode != nil && *info.ExitCode == 0
}

func (m *Manager) handleExit(s *Session) {
	cfg := m.cfg.Get()
	if shouldCloseTab(s.Info(), cfg.CloseTabOnCleanExit) {
		_ = m.Delete(s.ID)
		return
	}
	m.dropDetector(s.ID)
	onChange, _, _, onExit := m.hooks()
	if onExit != nil {
		onExit(s)
	}
	if onChange != nil {
		onChange()
	}
}

func (m *Manager) fallbackLoop() {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-m.stopFB:
			return
		case <-t.C:
			m.pollFallback()
		}
	}
}

func (m *Manager) pollFallback() {
	m.mu.RLock()
	list := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		list = append(list, s)
	}
	m.mu.RUnlock()
	onChange, _, onEvent, _ := m.hooks()

	changed := false
	for _, s := range list {
		info := s.Info()
		if info.State == StateExited {
			continue
		}
		m.observeForeground(s)

		running, name := foregroundInfo(s)
		before := info.State
		switch {
		case running && isRemoteClient(name):
			// A login client hides the far side from both detectors, so the
			// screen is the only signal left. This runs for integrated
			// sessions too — see SetRemoteState.
			s.SetRemoteState(remoteRunning(s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive})), name)
		case info.Integrated:
			// OSC events carry the state; there is nothing to approximate.
		default:
			s.SetFallbackState(running, name)
		}
		after := s.Info().State
		if before != after {
			changed = true
			if onEvent != nil {
				onEvent(s, osc.Event{})
			}
		}
	}
	if changed && onChange != nil {
		onChange()
	}
}

func foregroundInfo(s *Session) (bool, string) {
	ptmx := s.PTY()
	if ptmx == nil {
		return false, ""
	}
	rc, err := ptmx.SyscallConn()
	if err != nil {
		return false, ""
	}
	var fg int32
	var errno syscall.Errno
	if err := rc.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(syscall.TIOCGPGRP), uintptr(unsafe.Pointer(&fg)))
	}); err != nil || errno != 0 || fg <= 0 {
		return false, ""
	}
	shellPID := s.CmdProcessPID()
	if shellPID == 0 || int(fg) == shellPID {
		return false, ""
	}
	out, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(int(fg))).Output()
	if err != nil {
		return true, ""
	}
	return true, strings.TrimSpace(string(out))
}
