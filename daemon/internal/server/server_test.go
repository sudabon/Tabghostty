package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/notifyarbiter"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/session"
)

func testConfigStore(t *testing.T) *config.Store {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	store, err := config.LoadOrCreate()
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func TestSendDoesNotBlockOnSlowClient(t *testing.T) {
	serverConn := make(chan *websocket.Conn, 1)
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		serverConn <- conn
	}))
	defer httpServer.Close()

	clientConn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(httpServer.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	conn := <-serverConn
	if tcp, ok := conn.UnderlyingConn().(*net.TCPConn); ok {
		if err := tcp.SetWriteBuffer(1024); err != nil {
			t.Fatal(err)
		}
	}
	c := &wsClient{
		conn:   conn,
		attach: map[string]bool{},
		send:   make(chan []byte, 256),
		quit:   make(chan struct{}),
	}
	h := &Hub{}
	returned := make(chan struct{})
	go func() {
		h.send(c, map[string]any{"data": strings.Repeat("x", 4*1024*1024)})
		close(returned)
	}()

	fast := false
	select {
	case <-returned:
		fast = true
	case <-time.After(250 * time.Millisecond):
	}
	_ = clientConn.Close()
	_ = conn.Close()
	if !fast {
		<-returned
		t.Fatal("send blocked on a client that was not reading")
	}
}

func TestBroadcastBuffersOutputDuringReplay(t *testing.T) {
	c := &wsClient{
		attach:       map[string]bool{"session": true},
		replaying:    map[string]bool{"session": true},
		pending:      map[string][][]byte{},
		pendingBytes: map[string]int{},
		send:         make(chan []byte, 1),
		quit:         make(chan struct{}),
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}
	s := &session.Session{ID: "session"}

	h.broadcastOutput(s, []byte("live"))

	if len(c.send) != 0 {
		t.Fatal("live output was sent before replay completed")
	}
	if got := c.pending["session"]; len(got) != 1 || string(got[0]) != "live" {
		t.Fatalf("pending output = %#v, want one live chunk", got)
	}
}

func TestReplayPendingOutputIsBounded(t *testing.T) {
	c := &wsClient{
		attach:       map[string]bool{"session": true},
		replaying:    map[string]bool{"session": true},
		pending:      map[string][][]byte{},
		pendingBytes: map[string]int{},
		send:         make(chan []byte, 1),
		quit:         make(chan struct{}),
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}

	h.broadcastOutput(&session.Session{ID: "session"}, make([]byte, 4*1024*1024+1))

	if c.pendingBytes["session"] != -1 || len(c.pending["session"]) != 0 {
		t.Fatal("oversized replay pending output was retained")
	}
}

func TestAttachOverflowNotifiesClient(t *testing.T) {
	c := &wsClient{
		attach:       map[string]bool{"session": true},
		replaying:    map[string]bool{"session": true},
		pending:      map[string][][]byte{},
		pendingBytes: map[string]int{},
		send:         make(chan []byte, 4),
		quit:         make(chan struct{}),
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}

	h.broadcastOutput(&session.Session{ID: "session"}, make([]byte, 4*1024*1024+1))
	if !h.flushAttachPending(c, "session") {
		t.Fatal("expected overflow during attach flush")
	}

	select {
	case raw := <-c.send:
		if !strings.Contains(string(raw), `"code":"attach_overflow"`) {
			t.Fatalf("message = %s, want attach_overflow error", raw)
		}
	default:
		t.Fatal("expected attach_overflow error message")
	}
	if c.replaying["session"] {
		t.Fatal("replaying should be cleared after overflow")
	}
}

func TestResizeRejectsOutOfRangeDimensions(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, nil)
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{manager: manager, logger: log.New(io.Discard, "", 0)}

	h.handleClient(nil, clientMsg{T: "resize", SID: s.ID, Cols: 65536, Rows: 24})

	if s.Cols != 120 || s.Rows != 40 {
		t.Fatalf("size = %dx%d, want 120x40", s.Cols, s.Rows)
	}
}

func TestCreateSessionRejectsMalformedJSON(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, nil)
	defer manager.Close()
	srv := &Server{hub: &Hub{manager: manager}}
	req := httptest.NewRequest(http.MethodPost, "/api/sessions", strings.NewReader(`{"cwd":123}`))
	rec := httptest.NewRecorder()

	srv.handleCreateSession(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}

func TestInputWriteFailureIsLogged(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, nil)
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	h := &Hub{manager: manager, logger: log.New(&logs, "", 0)}

	h.handleClient(nil, clientMsg{
		T:    "input",
		SID:  s.ID,
		Data: base64.StdEncoding.EncodeToString([]byte("x")),
	})

	if got := logs.String(); !strings.Contains(got, "session "+s.ID+" write:") {
		t.Fatalf("log = %q, want session write error", got)
	}
}

func TestRunReturnsErrAlreadyRunningWhenPortAlreadyListening(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	hub := NewHub(manager, store, log.New(io.Discard, "", 0))
	httpSrv := httptest.NewUnstartedServer(nil)
	defer httpSrv.Close()
	port := httpSrv.Listener.Addr().(*net.TCPAddr).Port
	if _, err := store.Patch(map[string]any{"port": port}); err != nil {
		t.Fatal(err)
	}
	existing := New(store, log.New(io.Discard, "", 0), hub, nil)
	httpSrv.Config.Handler = existing.Handler()
	httpSrv.Start()

	var logs bytes.Buffer
	srv := New(store, log.New(&logs, "", 0), hub, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	err := srv.Run(ctx)
	if !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("Run = %v, want ErrAlreadyRunning", err)
	}
	if !strings.Contains(logs.String(), "already listening") {
		t.Fatalf("log = %q, want already listening message", logs.String())
	}
}

func TestRunRechecksIdentityAfterBindRace(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	hub := NewHub(manager, store, log.New(io.Discard, "", 0))
	httpSrv := httptest.NewUnstartedServer(nil)
	defer httpSrv.Close()
	port := httpSrv.Listener.Addr().(*net.TCPAddr).Port
	if _, err := store.Patch(map[string]any{"port": port}); err != nil {
		t.Fatal(err)
	}
	existing := New(store, log.New(io.Discard, "", 0), hub, nil)
	var probes atomic.Int32
	httpSrv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if probes.Add(1) == 1 {
			http.NotFound(w, r)
			return
		}
		existing.Handler().ServeHTTP(w, r)
	})
	httpSrv.Start()

	srv := New(store, log.New(io.Discard, "", 0), hub, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := srv.Run(ctx)
	if !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("Run = %v, want ErrAlreadyRunning after bind race", err)
	}
	if probes.Load() < 2 {
		t.Fatalf("probe count = %d, want a post-bind retry", probes.Load())
	}
}

func TestLoopbackListening(t *testing.T) {
	store := testConfigStore(t)
	httpSrv := httptest.NewUnstartedServer(nil)
	defer httpSrv.Close()
	port := httpSrv.Listener.Addr().(*net.TCPAddr).Port
	if _, err := store.Patch(map[string]any{"port": port}); err != nil {
		t.Fatal(err)
	}
	srv := New(store, log.New(io.Discard, "", 0), nil, nil)
	httpSrv.Config.Handler = srv.Handler()
	httpSrv.Start()
	if !LoopbackListening(port) {
		t.Fatal("expected WebTabinal server to report true")
	}
	httpSrv.Close()
	deadline := time.Now().Add(2 * time.Second)
	for LoopbackListening(port) {
		if time.Now().After(deadline) {
			t.Fatal("expected closed port to report false")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestLoopbackListeningRejectsUnrelatedHTTPServer(t *testing.T) {
	httpSrv := httptest.NewServer(http.NotFoundHandler())
	defer httpSrv.Close()
	u, err := url.Parse(httpSrv.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	if LoopbackListening(port) {
		t.Fatal("expected unrelated HTTP server to report false")
	}
}

func TestLoopbackListeningDoesNotFollowRedirects(t *testing.T) {
	redirected := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirected = true
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	defer redirect.Close()
	u, err := url.Parse(redirect.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	if LoopbackListening(port) {
		t.Fatal("expected redirecting HTTP server to report false")
	}
	if redirected {
		t.Fatal("probe followed redirect away from the configured loopback port")
	}
}

func TestLoopbackListeningPlainTCPOnly(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if LoopbackListening(port) {
		t.Fatal("expected plain TCP listener without WebTabinal HTTP to report false")
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestRunStopsWhenContextIsCanceled(t *testing.T) {
	store := testConfigStore(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Patch(map[string]any{"port": port}); err != nil {
		t.Fatal(err)
	}
	srv := New(store, log.New(io.Discard, "", 0), nil, nil)
	runner, ok := any(srv).(interface {
		Run(context.Context) error
	})
	if !ok {
		t.Fatal("Server does not implement Run(context.Context)")
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		result <- runner.Run(ctx)
	}()

	deadline := time.Now().Add(2 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", addr, 50*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			break
		}
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("server did not listen on %s: %v", addr, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after cancellation")
	}
}

func TestSecurityUsesPortBoundAtServerCreation(t *testing.T) {
	store := testConfigStore(t)
	srv := New(store, log.New(io.Discard, "", 0), nil, nil)
	if _, err := store.Patch(map[string]any{"port": 9000}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8642/", nil)
	req.Host = "127.0.0.1:8642"
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestBroadcastNotifyDoesNotRequireAttach(t *testing.T) {
	c := &wsClient{
		attach: map[string]bool{},
		send:   make(chan []byte, 2),
		quit:   make(chan struct{}),
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}
	s := &session.Session{ID: "session", State: session.StateRunning, Command: "codex"}

	h.broadcastStateFromEvent(s, osc.Event{Kind: osc.EventNotify, Title: "Codex", Body: "needs approval"})

	select {
	case raw := <-c.send:
		var msg map[string]any
		if err := json.Unmarshal(raw, &msg); err != nil {
			t.Fatal(err)
		}
		if msg["t"] != "notify" || msg["sid"] != "session" || msg["title"] != "Codex" || msg["body"] != "needs approval" {
			t.Fatalf("notify frame = %#v", msg)
		}
	default:
		t.Fatal("expected notify frame for unattached client")
	}
	if len(c.send) != 0 {
		t.Fatal("unexpected extra WS frame on notify")
	}
}

func TestBroadcastNotifySkipsEmpty(t *testing.T) {
	c := &wsClient{
		attach: map[string]bool{},
		send:   make(chan []byte, 1),
		quit:   make(chan struct{}),
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}
	s := &session.Session{ID: "session", State: session.StateRunning}

	h.broadcastStateFromEvent(s, osc.Event{Kind: osc.EventNotify})

	if len(c.send) != 0 {
		t.Fatal("empty notify should not produce a WS frame")
	}
}

func TestSecurityHeadersAreSet(t *testing.T) {
	store := testConfigStore(t)
	srv := New(store, log.New(io.Discard, "", 0), nil, nil)
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8642/", nil)
	req.Host = "127.0.0.1:8642"
	rec := httptest.NewRecorder()

	srv.Handler().ServeHTTP(rec, req)

	headers := map[string]string{
		"X-Frame-Options":         "DENY",
		"X-Content-Type-Options":  "nosniff",
		"Content-Security-Policy": "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; frame-ancestors 'none'; style-src 'self' 'unsafe-inline'",
	}
	for name, want := range headers {
		if got := rec.Header().Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
}

func recvJSON(t *testing.T, c *wsClient) map[string]any {
	t.Helper()
	select {
	case raw := <-c.send:
		var msg map[string]any
		if err := json.Unmarshal(raw, &msg); err != nil {
			t.Fatal(err)
		}
		return msg
	default:
		t.Fatal("expected WS frame")
		return nil
	}
}

func TestSessionListIncludesExplicitNoneAgentState(t *testing.T) {
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	s, err := mgr.Create("")
	if err != nil {
		t.Fatal(err)
	}
	info := mgr.SessionInfo(s)
	if info.Agent != "" || info.AgentState != "none" {
		t.Fatalf("ordinary shell agent snapshot = %+v", info)
	}
	if strings.Contains(info.AgentStateDetail, "\x1b") || strings.Contains(info.AgentStateDetail, "pattern=") && strings.Contains(info.AgentStateDetail, " ") {
		t.Fatalf("diagnostic leaked screen text: %q", info.AgentStateDetail)
	}
}

func TestBroadcastAgentStateDoesNotRequireAttach(t *testing.T) {
	c := &wsClient{
		attach: map[string]bool{},
		send:   make(chan []byte, 2),
		quit:   make(chan struct{}),
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}
	since := time.Unix(1_700_000_000, 0).UTC()
	h.broadcastAgentState(agentdetect.Snapshot{
		SessionID: "session",
		AgentID:   "codex",
		State:     agentdetect.StateBlocked,
		Since:     since,
		Signal:    agentdetect.SignalScreen,
		Detail:    "pattern=ask line=0",
	})
	msg := recvJSON(t, c)
	if msg["t"] != "agent_state" || msg["sid"] != "session" || msg["agent"] != "codex" || msg["agent_state"] != "blocked" {
		t.Fatalf("agent_state frame = %#v", msg)
	}
	if msg["agent_state_since"] != since.Format(time.RFC3339) || msg["agent_state_signal"] != "screen" {
		t.Fatalf("agent_state metadata = %#v", msg)
	}
	if msg["agent_state_detail"] != "pattern=ask line=0" {
		t.Fatalf("detail = %#v", msg["agent_state_detail"])
	}
	if len(c.send) != 0 {
		t.Fatal("unexpected extra WS frame")
	}
}

func TestShellStateFrameUnchangedWhenAgentIdle(t *testing.T) {
	c := &wsClient{send: make(chan []byte, 2), quit: make(chan struct{})}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}
	info := session.Info{ID: "session", Cwd: "/tmp", Command: "codex", State: session.StateRunning, AgentState: "idle"}
	h.broadcastState(info)
	msg := recvJSON(t, c)
	if msg["t"] != "state" || msg["state"] != "running" || msg["sid"] != "session" {
		t.Fatalf("shell state frame = %#v", msg)
	}
	if _, ok := msg["agent_state"]; ok {
		t.Fatalf("shell state frame unexpectedly includes agent_state: %#v", msg)
	}
}

func TestInitialSessionsPrecedeDeferredAgentState(t *testing.T) {
	c := &wsClient{
		send:    make(chan []byte, 4),
		quit:    make(chan struct{}),
		syncing: true,
	}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}
	h.broadcastAgentState(agentdetect.Snapshot{
		SessionID: "s1",
		AgentID:   "codex",
		State:     agentdetect.StateBlocked,
		Since:     time.Unix(1_700_000_000, 0).UTC(),
		Signal:    agentdetect.SignalScreen,
	})
	h.sendNow(c, map[string]any{"t": "sessions", "list": []any{}})
	h.finishClientSync(c)

	first := recvJSON(t, c)
	if first["t"] != "sessions" {
		t.Fatalf("first frame = %#v, want sessions", first)
	}
	second := recvJSON(t, c)
	if second["t"] != "agent_state" || second["agent_state"] != "blocked" {
		t.Fatalf("second frame = %#v, want deferred agent_state", second)
	}
}

func TestAttentionDedupeOSCThenScreen(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	c := &wsClient{send: make(chan []byte, 8), quit: make(chan struct{})}
	store := testConfigStore(t)
	s := &session.Session{ID: "session", State: session.StateRunning, Command: "codex"}
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	h := &Hub{
		manager:   mgr,
		cfg:       store,
		clients:   map[*wsClient]struct{}{c: {}},
		arbiter:   notifyarbiter.New(clock),
		lastAgent: map[string]agentdetect.State{"session": agentdetect.StateWorking},
	}
	eng := agentdetect.New(agentdetect.Options{
		Registry: agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
		Clock:    clock,
	})
	mgr.SetEngine(eng)
	// Install the live session id into the manager via Create so Get() works.
	live, err := mgr.Create("")
	if err != nil {
		t.Fatal(err)
	}
	s.ID = live.ID
	// Resolve an identity so the OSC leg is banner-eligible and consumes the
	// attention window; otherwise the dedupe under test never engages.
	eng.OnCommandStart(live.ID, "codex")
	h.lastAgent[live.ID] = agentdetect.StateWorking
	drainClient(c)

	h.broadcastNotify(s, osc.Event{Kind: osc.EventNotify, Title: "Codex", Body: "needs approval"})
	oscMsg := recvJSON(t, c)
	if oscMsg["t"] != "notify" || oscMsg["kind"] != nil {
		t.Fatalf("OSC notify = %#v", oscMsg)
	}

	clock.Advance(2 * time.Second)
	h.onAgentSnapshot(agentdetect.Snapshot{
		SessionID: live.ID,
		AgentID:   agentdetect.IDCodex,
		State:     agentdetect.StateBlocked,
		Since:     clock.Now(),
		Signal:    agentdetect.SignalScreen,
	})
	stateMsg := recvJSON(t, c)
	if stateMsg["t"] != "agent_state" || stateMsg["agent_state"] != "blocked" {
		t.Fatalf("blocked transition = %#v", stateMsg)
	}
	if len(c.send) != 0 {
		t.Fatalf("screen notify should be suppressed, extra %#v", recvJSON(t, c))
	}
}

func TestAttentionDedupeScreenThenOSC(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	c := &wsClient{send: make(chan []byte, 8), quit: make(chan struct{})}
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	eng := agentdetect.New(agentdetect.Options{
		Registry: agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
		Clock:    clock,
	})
	mgr.SetEngine(eng)
	live, err := mgr.Create("")
	if err != nil {
		t.Fatal(err)
	}
	// Resolve an identity so the OSC leg is banner-eligible; a suppressed
	// banner would not be deduped against the earlier screen event.
	eng.OnCommandStart(live.ID, "codex")
	h := &Hub{
		manager:   mgr,
		cfg:       store,
		clients:   map[*wsClient]struct{}{c: {}},
		arbiter:   notifyarbiter.New(clock),
		lastAgent: map[string]agentdetect.State{live.ID: agentdetect.StateWorking},
	}
	drainClient(c)

	h.onAgentSnapshot(agentdetect.Snapshot{
		SessionID: live.ID,
		AgentID:   agentdetect.IDCodex,
		State:     agentdetect.StateBlocked,
		Since:     clock.Now(),
		Signal:    agentdetect.SignalScreen,
	})
	var sawNotify, sawState bool
	for len(c.send) > 0 {
		msg := recvJSON(t, c)
		switch msg["t"] {
		case "notify":
			sawNotify = true
			if msg["kind"] != "agent_blocked" || msg["source"] != "screen" {
				t.Fatalf("blocked notify = %#v", msg)
			}
		case "agent_state":
			sawState = true
		}
	}
	if !sawNotify || !sawState {
		t.Fatal("expected blocked notify and agent_state")
	}

	clock.Advance(time.Second)
	h.broadcastNotify(live, osc.Event{Kind: osc.EventNotify, Title: "Codex", Body: "needs approval"})
	if len(c.send) != 0 {
		t.Fatalf("OSC notify should be suppressed, extra %#v", recvJSON(t, c))
	}
}

func TestAttentionDedupeIndependentSessionsAndLaterWindow(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	c := &wsClient{send: make(chan []byte, 8), quit: make(chan struct{})}
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}, arbiter: notifyarbiter.New(clock)}
	h.broadcastNotify(&session.Session{ID: "a"}, osc.Event{Kind: osc.EventNotify, Title: "A", Body: "one"})
	h.broadcastNotify(&session.Session{ID: "b"}, osc.Event{Kind: osc.EventNotify, Title: "B", Body: "two"})
	if recvJSON(t, c)["sid"] != "a" || recvJSON(t, c)["sid"] != "b" {
		t.Fatal("both sessions should notify")
	}
	clock.Advance(notifyarbiter.Window)
	h.broadcastNotify(&session.Session{ID: "a"}, osc.Event{Kind: osc.EventNotify, Title: "A", Body: "again"})
	if recvJSON(t, c)["body"] != "again" {
		t.Fatal("post-window event should notify")
	}
}

func TestRepeatedBlockedDoesNotNotifyAgain(t *testing.T) {
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	c := &wsClient{send: make(chan []byte, 8), quit: make(chan struct{})}
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	live, err := mgr.Create("")
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{
		manager:   mgr,
		cfg:       store,
		clients:   map[*wsClient]struct{}{c: {}},
		arbiter:   notifyarbiter.New(clock),
		lastAgent: map[string]agentdetect.State{live.ID: agentdetect.StateWorking},
	}
	drainClient(c)
	snap := agentdetect.Snapshot{SessionID: live.ID, AgentID: agentdetect.IDCodex, State: agentdetect.StateBlocked, Since: clock.Now(), Signal: agentdetect.SignalScreen}
	h.onAgentSnapshot(snap)
	drainClient(c)
	clock.Advance(notifyarbiter.Window)
	h.onAgentSnapshot(snap)
	for len(c.send) > 0 {
		msg := recvJSON(t, c)
		if msg["t"] == "notify" {
			t.Fatalf("repeated blocked evidence notified: %#v", msg)
		}
	}
}

func TestNotifyOnBlockedFalseSkipsScreenNotify(t *testing.T) {
	c := &wsClient{send: make(chan []byte, 8), quit: make(chan struct{})}
	store := testConfigStore(t)
	if _, err := store.Patch(map[string]any{"state": map[string]any{"notify_on_blocked": false}}); err != nil {
		t.Fatal(err)
	}
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	live, err := mgr.Create("")
	if err != nil {
		t.Fatal(err)
	}
	h := &Hub{
		manager:   mgr,
		cfg:       store,
		clients:   map[*wsClient]struct{}{c: {}},
		lastAgent: map[string]agentdetect.State{live.ID: agentdetect.StateWorking},
	}
	drainClient(c)
	h.onAgentSnapshot(agentdetect.Snapshot{SessionID: live.ID, AgentID: agentdetect.IDCodex, State: agentdetect.StateBlocked, Signal: agentdetect.SignalScreen, Since: time.Now()})
	sawState := false
	for len(c.send) > 0 {
		msg := recvJSON(t, c)
		if msg["t"] == "notify" {
			t.Fatalf("screen notify emitted while disabled: %#v", msg)
		}
		if msg["t"] == "agent_state" {
			sawState = true
		}
	}
	if !sawState {
		t.Fatal("pill/state transport should still update")
	}
}

func drainClient(c *wsClient) {
	for {
		select {
		case <-c.send:
		default:
			return
		}
	}
}
