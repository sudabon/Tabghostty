package server

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/notifyarbiter"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/session"
)

// Notification kinds carried by the notify frame.
const (
	notifyKindAgentIdle    = "agent_idle"
	notifyKindAgentBlocked = "agent_blocked"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true }, // Host/Origin already checked
}

type clientMsg struct {
	T    string `json:"t"`
	SID  string `json:"sid"`
	Data string `json:"data,omitempty"`
	Cols int    `json:"cols,omitempty"`
	Rows int    `json:"rows,omitempty"`
	// Tabghostty: attach asks for binary replay/output frames (ws_binary.go).
	Binary bool `json:"binary,omitempty"`
}

type Hub struct {
	manager *session.Manager
	cfg     *config.Store
	logger  *log.Logger
	arbiter *notifyarbiter.Arbiter

	mu        sync.Mutex
	clients   map[*wsClient]struct{}
	lastAgent map[string]agentdetect.State
}

type wsClient struct {
	conn         *websocket.Conn
	mu           sync.Mutex
	attach       map[string]bool
	replaying    map[string]bool
	pending      map[string][][]byte
	pendingBytes map[string]int
	send         chan []byte
	closeOnce    sync.Once
	quit         chan struct{}
	syncing      bool
	deferred     [][]byte
	binary       map[string]bool // Tabghostty: sids attached with binary frames (ws_binary.go)
}

func NewHub(manager *session.Manager, cfg *config.Store, logger *log.Logger) *Hub {
	h := &Hub{
		manager:   manager,
		cfg:       cfg,
		logger:    logger,
		arbiter:   notifyarbiter.New(nil),
		clients:   make(map[*wsClient]struct{}),
		lastAgent: map[string]agentdetect.State{},
	}
	manager.SetHooks(
		h.broadcastSessions,
		h.broadcastOutput,
		h.broadcastStateFromEvent,
		h.broadcastStateFromExit,
	)
	manager.SetOnDrop(func(id string) {
		h.arbiter.Forget(id)
		h.mu.Lock()
		delete(h.lastAgent, id)
		h.mu.Unlock()
	})
	manager.SubscribeAgent(h.onAgentSnapshot)
	return h
}

func (h *Hub) SetArbiterClock(clock notifyarbiter.Clock) {
	h.arbiter = notifyarbiter.New(clock)
}

func (h *Hub) HandleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		h.logger.Printf("ws upgrade: %v", err)
		return
	}
	c := &wsClient{
		conn:         conn,
		attach:       map[string]bool{},
		replaying:    map[string]bool{},
		pending:      map[string][][]byte{},
		pendingBytes: map[string]int{},
		send:         make(chan []byte, 256),
		quit:         make(chan struct{}),
		syncing:      true,
	}
	h.mu.Lock()
	h.clients[c] = struct{}{}
	h.mu.Unlock()
	go h.writeClient(c)
	if err := conn.SetReadDeadline(time.Now().Add(60 * time.Second)); err != nil {
		h.logger.Printf("ws read deadline: %v", err)
		h.disconnect(c)
		return
	}
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	})

	// initial sync: enqueue snapshot before any deferred live transitions
	list := h.manager.List()
	h.sendNow(c, map[string]any{"t": "sessions", "list": list})
	for _, info := range list {
		h.sendNow(c, stateMsg(info))
	}
	h.finishClientSync(c)

	defer h.disconnect(c)

	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var msg clientMsg
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		h.handleClient(c, msg)
	}
}

func (h *Hub) handleClient(c *wsClient, msg clientMsg) {
	switch msg.T {
	case "attach":
		c.mu.Lock()
		c.attach[msg.SID] = true
		c.replaying[msg.SID] = true
		c.setBinaryLocked(msg.SID, msg.Binary) // Tabghostty
		c.pending[msg.SID] = nil
		c.pendingBytes[msg.SID] = 0
		c.mu.Unlock()
		s, ok := h.manager.Get(msg.SID)
		if !ok {
			c.mu.Lock()
			delete(c.replaying, msg.SID)
			delete(c.pending, msg.SID)
			delete(c.pendingBytes, msg.SID)
			c.mu.Unlock()
			return
		}
		buf := s.Ring.Bytes()
		const chunk = 24 * 1024
		if c.usesBinary(msg.SID) { // Tabghostty: binary frames (ws_binary.go)
			h.sendReplayBinary(c, msg.SID, buf, chunk)
		} else if len(buf) == 0 {
			h.send(c, map[string]any{"t": "replay", "sid": msg.SID, "data": "", "done": true})
		} else {
			for i := 0; i < len(buf); i += chunk {
				end := i + chunk
				if end > len(buf) {
					end = len(buf)
				}
				h.send(c, map[string]any{
					"t":    "replay",
					"sid":  msg.SID,
					"data": base64.StdEncoding.EncodeToString(buf[i:end]),
					"done": end >= len(buf),
				})
			}
		}
		_ = h.flushAttachPending(c, msg.SID)
		h.send(c, stateMsg(s.Info()))
	case "input":
		s, ok := h.manager.Get(msg.SID)
		if !ok {
			return
		}
		raw, err := base64.StdEncoding.DecodeString(msg.Data)
		if err != nil {
			return
		}
		if err := s.Write(raw); err != nil {
			h.logger.Printf("session %s write: %v", msg.SID, err)
		}
	case "resize":
		if msg.Cols <= 0 || msg.Cols > 10000 || msg.Rows <= 0 || msg.Rows > 10000 {
			return
		}
		s, ok := h.manager.Get(msg.SID)
		if !ok {
			return
		}
		_ = s.Resize(uint16(msg.Cols), uint16(msg.Rows))
	}
}

func (h *Hub) broadcastOutput(s *session.Session, data []byte) {
	payload := map[string]any{
		"t":    "output",
		"sid":  s.ID,
		"data": base64.StdEncoding.EncodeToString(data),
	}
	const maxPendingBytes = 4 * 1024 * 1024
	for _, c := range h.clientSnapshot() {
		c.mu.Lock()
		ok := c.attach[s.ID]
		if ok && c.replaying[s.ID] {
			pendingBytes := c.pendingBytes[s.ID]
			if pendingBytes >= 0 && pendingBytes+len(data) <= maxPendingBytes {
				c.pending[s.ID] = append(c.pending[s.ID], data)
				c.pendingBytes[s.ID] = pendingBytes + len(data)
			} else {
				c.pending[s.ID] = nil
				c.pendingBytes[s.ID] = -1
			}
			c.mu.Unlock()
			continue
		}
		c.mu.Unlock()
		if ok && c.usesBinary(s.ID) { // Tabghostty: binary frames (ws_binary.go)
			h.sendOutputBinary(c, s.ID, data)
		} else if ok {
			h.send(c, payload)
		}
	}
}

func (h *Hub) sendAttachOverflow(c *wsClient, sid string) {
	h.send(c, map[string]any{
		"t":       "error",
		"sid":     sid,
		"code":    "attach_overflow",
		"message": "Live output overflowed during attach; re-attach required",
	})
}

// flushAttachPending drains buffered live output after ring replay.
// If pending overflowed, it notifies the client and returns true.
func (h *Hub) flushAttachPending(c *wsClient, sid string) (overflowed bool) {
	for {
		c.mu.Lock()
		pending := c.pending[sid]
		overflowed = c.pendingBytes[sid] < 0
		c.pending[sid] = nil
		c.pendingBytes[sid] = 0
		if overflowed {
			c.replaying[sid] = false
			delete(c.pending, sid)
			delete(c.pendingBytes, sid)
			c.mu.Unlock()
			h.sendAttachOverflow(c, sid)
			return true
		}
		if len(pending) == 0 {
			c.replaying[sid] = false
			delete(c.pending, sid)
			delete(c.pendingBytes, sid)
			c.mu.Unlock()
			return false
		}
		c.mu.Unlock()
		for _, data := range pending {
			if c.usesBinary(sid) { // Tabghostty: binary frames (ws_binary.go)
				h.sendOutputBinary(c, sid, data)
				continue
			}
			h.send(c, map[string]any{
				"t":    "output",
				"sid":  sid,
				"data": base64.StdEncoding.EncodeToString(data),
			})
		}
	}
}

func (h *Hub) broadcastStateFromEvent(s *session.Session, ev osc.Event) {
	if ev.Kind == osc.EventNotify {
		h.broadcastNotify(s, ev)
		return
	}
	h.broadcastState(s.Info())
}

func (h *Hub) broadcastNotify(s *session.Session, ev osc.Event) {
	if strings.TrimSpace(ev.Title) == "" && strings.TrimSpace(ev.Body) == "" {
		return
	}
	if !h.allowAttention(s.ID) {
		return
	}
	payload := map[string]any{
		"t":     "notify",
		"sid":   s.ID,
		"title": ev.Title,
		"body":  ev.Body,
	}
	for _, c := range h.clientSnapshot() {
		h.send(c, payload)
	}
}

// notifyFromHook broadcasts a turn-completion report from a coding agent's stop
// hook. A report for a session that has already gone is dropped, because a hook
// racing session teardown must not fail the agent's turn.
func (h *Hub) notifyFromHook(sessionID, title, body, kind string) {
	if h.manager == nil {
		return
	}
	if _, ok := h.manager.Get(sessionID); !ok {
		return
	}
	if !h.allowAttention(sessionID) {
		return
	}
	payload := map[string]any{
		"t":      "notify",
		"sid":    sessionID,
		"title":  title,
		"body":   body,
		"kind":   kind,
		"source": "hook",
	}
	for _, c := range h.clientSnapshot() {
		h.send(c, payload)
	}
}

func (h *Hub) allowAttention(sessionID string) bool {
	if h.arbiter == nil {
		return true
	}
	return h.arbiter.Allow(sessionID)
}

func (h *Hub) onAgentSnapshot(snap agentdetect.Snapshot) {
	h.mu.Lock()
	prev := h.lastAgent[snap.SessionID]
	h.lastAgent[snap.SessionID] = snap.State
	h.mu.Unlock()
	h.broadcastAgentState(snap)

	kind, body, ok := attentionEvent(prev, snap.State)
	if !ok {
		return
	}
	if h.cfg == nil {
		return
	}
	st := h.cfg.Get().State
	if kind == notifyKindAgentBlocked && !st.NotifyOnBlocked {
		return
	}
	// A prompt return is screen-derived, so it cannot outlive detection, and it
	// is opt-in because quiescence cannot tell a finished turn from a pause.
	if kind == notifyKindAgentIdle && (!st.Enabled || !st.NotifyOnIdle) {
		return
	}
	if h.manager == nil {
		return
	}
	s, found := h.manager.Get(snap.SessionID)
	if !found {
		return
	}
	if !h.allowAttention(snap.SessionID) {
		return
	}
	payload := map[string]any{
		"t":      "notify",
		"sid":    s.ID,
		"title":  h.agentDisplayName(snap.AgentID),
		"body":   body,
		"kind":   kind,
		"source": "screen",
	}
	for _, c := range h.clientSnapshot() {
		h.send(c, payload)
	}
}

// attentionEvent classifies an agent state transition as an attention event.
// Entering `idle` from `none` is a session's initial idle-safe resolution and
// entering it from `blocked` follows a user response, so neither asks for
// attention.
func attentionEvent(prev, next agentdetect.State) (kind, body string, ok bool) {
	switch {
	case next == agentdetect.StateBlocked && prev != agentdetect.StateBlocked:
		return notifyKindAgentBlocked, "Waiting for input", true
	case next == agentdetect.StateIdle && prev == agentdetect.StateWorking:
		return notifyKindAgentIdle, "Ready for input", true
	default:
		return "", "", false
	}
}

func (h *Hub) agentDisplayName(id string) string {
	if id == "" {
		return "Agent"
	}
	if h.manager == nil {
		return id
	}
	if name := h.manager.AgentDisplayName(id); name != "" {
		return name
	}
	return id
}

func (h *Hub) broadcastAgentState(snap agentdetect.Snapshot) {
	payload := agentStateMsg(snap)
	for _, c := range h.clientSnapshot() {
		h.send(c, payload)
	}
}

func (h *Hub) broadcastStateFromExit(s *session.Session) {
	h.broadcastState(s.Info())
	h.broadcastSessions()
}

func (h *Hub) broadcastState(info session.Info) {
	payload := stateMsg(info)
	for _, c := range h.clientSnapshot() {
		h.send(c, payload)
	}
}

func (h *Hub) broadcastSessions() {
	payload := map[string]any{"t": "sessions", "list": h.manager.List()}
	for _, c := range h.clientSnapshot() {
		h.send(c, payload)
	}
}

func (h *Hub) clientSnapshot() []*wsClient {
	h.mu.Lock()
	defer h.mu.Unlock()
	clients := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	return clients
}

func (h *Hub) send(c *wsClient, v any) {
	b, ok := h.marshal(v)
	if !ok {
		return
	}
	h.sendBytes(c, b)
}

// sendBytes queues an encoded frame, deferring it until the initial sync is done.
// Tabghostty: split out of send so binary frames share the same path (ws_binary.go).
func (h *Hub) sendBytes(c *wsClient, b []byte) {
	c.mu.Lock()
	if c.syncing {
		c.deferred = append(c.deferred, b)
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()
	h.enqueue(c, b)
}

func (h *Hub) sendNow(c *wsClient, v any) {
	b, ok := h.marshal(v)
	if !ok {
		return
	}
	h.enqueue(c, b)
}

func (h *Hub) finishClientSync(c *wsClient) {
	c.mu.Lock()
	c.syncing = false
	deferred := c.deferred
	c.deferred = nil
	c.mu.Unlock()
	for _, b := range deferred {
		h.enqueue(c, b)
	}
}

func (h *Hub) marshal(v any) ([]byte, bool) {
	b, err := json.Marshal(v)
	if err != nil {
		if h.logger != nil {
			h.logger.Printf("ws marshal: %v", err)
		}
		return nil, false
	}
	return b, true
}

func (h *Hub) enqueue(c *wsClient, b []byte) {
	select {
	case <-c.quit:
		return
	default:
	}
	select {
	case c.send <- b:
	case <-c.quit:
	default:
		h.disconnect(c)
	}
}

func (h *Hub) writeClient(c *wsClient) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case b := <-c.send:
			if err := c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second)); err != nil {
				h.disconnect(c)
				return
			}
			if err := c.conn.WriteMessage(wsMessageType(b), b); err != nil { // Tabghostty: binary frames (ws_binary.go)
				h.disconnect(c)
				return
			}
		case <-ticker.C:
			if err := c.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second)); err != nil {
				h.disconnect(c)
				return
			}
		case <-c.quit:
			return
		}
	}
}

func (h *Hub) disconnect(c *wsClient) {
	c.closeOnce.Do(func() {
		close(c.quit)
		_ = c.conn.Close()
		h.mu.Lock()
		delete(h.clients, c)
		h.mu.Unlock()
	})
}

func agentStateMsg(snap agentdetect.Snapshot) map[string]any {
	since := ""
	if !snap.Since.IsZero() {
		since = snap.Since.UTC().Format(time.RFC3339)
	}
	state := snap.State
	if state == "" {
		state = agentdetect.StateNone
	}
	payload := map[string]any{
		"t":                  "agent_state",
		"sid":                snap.SessionID,
		"agent":              snap.AgentID,
		"agent_state":        state,
		"agent_state_since":  since,
		"agent_state_signal": snap.Signal,
	}
	if snap.Detail != "" {
		payload["agent_state_detail"] = snap.Detail
	}
	return payload
}

func stateMsg(info session.Info) map[string]any {
	return map[string]any{
		"t":          "state",
		"sid":        info.ID,
		"cwd":        info.Cwd,
		"cmd":        info.Command,
		"state":      info.State,
		"exit":       info.ExitCode,
		"integrated": info.Integrated,
		"run_ms":     info.RunMs,
	}
}
