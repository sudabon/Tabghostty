package session

import (
	"log"
	"time"

	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type sessionScreen struct{ s *Session }

func (p sessionScreen) Snapshot(opts vtscreen.SnapshotOptions) vtscreen.Snapshot {
	return p.s.ScreenSnapshot(opts)
}

type sessionInspector struct{ s *Session }

func (p sessionInspector) Inspect() agentdetect.ForegroundInfo {
	return agentdetect.SessionInspector{
		PTY:      p.s.PTY(),
		ShellPID: p.s.CmdProcessPID(),
		Screen:   sessionScreen{s: p.s},
	}.Inspect()
}

var (
	_ agentdetect.ScreenProvider = sessionScreen{}
	_ agentdetect.Inspector      = sessionInspector{}
)

func newAgentEngine(cfg *config.Store, logger *log.Logger) *agentdetect.Engine {
	st := config.Defaults().State
	if cfg != nil {
		st = cfg.Get().State
	}
	opts := agentdetect.LoadOptions{Logger: logger}
	if st.ManifestDir != "" {
		opts.LocalDir = st.ManifestDir
	}
	enabled := st.Enabled
	e := agentdetect.New(agentdetect.Options{
		Registry:    agentdetect.Load(opts),
		Debounce:    time.Duration(st.DebounceMs) * time.Millisecond,
		Quiescence:  time.Duration(st.QuiescenceMs) * time.Millisecond,
		BottomLines: st.BottomLines,
		Enabled:     &enabled,
	})
	return e
}

// SubscribeAgent registers a callback for identity/state transitions.
func (m *Manager) SubscribeAgent(fn func(agentdetect.Snapshot)) (cancel func()) {
	if e := m.currentEngine(); e != nil {
		return e.Subscribe(fn)
	}
	return func() {}
}

// ApplyStateConfig applies enabled/timing/line settings. Manifest directory is restart-only.
func (m *Manager) ApplyStateConfig(st config.StateConfig) {
	e := m.currentEngine()
	if e == nil {
		return
	}
	e.Configure(agentdetect.RuntimeConfig{
		Enabled:     st.Enabled,
		Debounce:    time.Duration(st.DebounceMs) * time.Millisecond,
		Quiescence:  time.Duration(st.QuiescenceMs) * time.Millisecond,
		BottomLines: st.BottomLines,
	})
}

func (m *Manager) currentEngine() *agentdetect.Engine {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.engine
}

// SetEngine replaces the agent-state engine. Intended for tests.
func (m *Manager) SetEngine(e *agentdetect.Engine) {
	m.mu.Lock()
	m.engine = e
	m.mu.Unlock()
}

// AgentSnapshot returns the current agent-state snapshot for a live session.
func (m *Manager) AgentSnapshot(id string) (agentdetect.Snapshot, bool) {
	if e := m.currentEngine(); e != nil {
		return e.Snapshot(id)
	}
	return agentdetect.Snapshot{}, false
}

// AgentDisplayName returns the manifest display name for an agent ID.
func (m *Manager) AgentDisplayName(id string) string {
	e := m.currentEngine()
	if e == nil || e.Registry() == nil || id == "" {
		return id
	}
	if man, ok := e.Registry().Manifest(id); ok && man.DisplayName != "" {
		return man.DisplayName
	}
	return id
}

func (m *Manager) openDetector(s *Session) {
	if e := m.currentEngine(); e != nil {
		e.Open(s.ID, sessionScreen{s: s}, sessionInspector{s: s})
	}
}

func (m *Manager) dropDetector(id string) {
	if e := m.currentEngine(); e != nil {
		e.Close(id)
	}
	m.mu.RLock()
	onDrop := m.onDrop
	m.mu.RUnlock()
	if onDrop != nil {
		onDrop(id)
	}
}

func (m *Manager) observeOutput(s *Session, n int) {
	if e := m.currentEngine(); e != nil {
		e.OnOutput(s.ID, n)
	}
}

func (m *Manager) observeEvent(s *Session, ev osc.Event) {
	e := m.currentEngine()
	if e == nil {
		return
	}
	switch ev.Kind {
	case osc.EventCmdStart:
		e.OnCommandStart(s.ID, ev.Command)
	case osc.EventCmdEnd:
		e.OnCommandEnd(s.ID)
	case osc.EventPrompt:
		e.OnPrompt(s.ID)
	case osc.EventNotify:
		kind := agentdetect.OSCKind(ev.OSC)
		if kind == 0 {
			kind = agentdetect.OSC9
		}
		e.OnOSC(s.ID, kind)
	}
}

func (m *Manager) observeForeground(s *Session) {
	if e := m.currentEngine(); e != nil {
		e.OnForeground(s.ID)
	}
}
