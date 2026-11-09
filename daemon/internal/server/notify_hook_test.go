package server

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/session"
)

// hookServer wires a Server over a live session with one registered WS client,
// so the hook notification endpoint can be exercised end to end through the
// real security middleware.
type hookServer struct {
	srv  *Server
	hub  *Hub
	conn *wsClient
	sess *session.Session
}

func newHookServer(t *testing.T) *hookServer {
	t.Helper()
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	hub := NewHub(mgr, store, log.New(io.Discard, "", 0))
	srv := New(store, log.New(io.Discard, "", 0), hub, nil)
	sess, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	c := &wsClient{send: make(chan []byte, 16), quit: make(chan struct{})}
	hub.mu.Lock()
	hub.clients[c] = struct{}{}
	hub.mu.Unlock()
	drainClient(c)
	return &hookServer{srv: srv, hub: hub, conn: c, sess: sess}
}

// post sends a notify report. An empty token omits authentication entirely.
func (h *hookServer) post(t *testing.T, sessionID, body, token, origin string) *httptest.ResponseRecorder {
	t.Helper()
	host := "127.0.0.1:8642"
	req := httptest.NewRequest(http.MethodPost, "http://"+host+"/api/sessions/"+sessionID+"/notify", strings.NewReader(body))
	req.Host = host
	req.Header.Set("Content-Type", "application/json")
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.srv.Handler().ServeHTTP(rec, req)
	return rec
}

func (h *hookServer) token() string { return h.srv.cfg.AuthToken() }

// nextNotify drains frames until a notify arrives, returning nil if none does.
func nextNotifyFrame(t *testing.T, c *wsClient) map[string]any {
	t.Helper()
	for len(c.send) > 0 {
		if msg := recvJSON(t, c); msg["t"] == "notify" {
			return msg
		}
	}
	return nil
}

func TestHookNotifyBroadcastsOnce(t *testing.T) {
	h := newHookServer(t)
	rec := h.post(t, h.sess.ID, `{"title":"Claude","body":"Turn complete"}`, h.token(), "")
	if rec.Code < 200 || rec.Code > 299 {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}

	msg := nextNotifyFrame(t, h.conn)
	if msg == nil {
		t.Fatal("expected a notify frame")
	}
	if msg["sid"] != h.sess.ID {
		t.Fatalf("sid = %#v, want %s", msg["sid"], h.sess.ID)
	}
	if msg["title"] != "Claude" || msg["body"] != "Turn complete" {
		t.Fatalf("notify frame = %#v", msg)
	}
	if msg["source"] != "hook" {
		t.Fatalf("source = %#v, want hook", msg["source"])
	}
	if extra := nextNotifyFrame(t, h.conn); extra != nil {
		t.Fatalf("expected exactly one notify, got another: %#v", extra)
	}
}

func TestHookNotifyDefaultsKindToAgentIdle(t *testing.T) {
	h := newHookServer(t)
	h.post(t, h.sess.ID, `{"title":"Claude","body":"Turn complete"}`, h.token(), "")

	msg := nextNotifyFrame(t, h.conn)
	if msg == nil {
		t.Fatal("expected a notify frame")
	}
	if msg["kind"] != "agent_idle" {
		t.Fatalf("kind = %#v, want agent_idle", msg["kind"])
	}
}

func TestHookNotifyKeepsExplicitKind(t *testing.T) {
	h := newHookServer(t)
	h.post(t, h.sess.ID, `{"title":"Claude","body":"Needs approval","kind":"agent_blocked"}`, h.token(), "")

	msg := nextNotifyFrame(t, h.conn)
	if msg == nil {
		t.Fatal("expected a notify frame")
	}
	if msg["kind"] != "agent_blocked" {
		t.Fatalf("kind = %#v, want agent_blocked", msg["kind"])
	}
}

// A hook can fire while its session is being torn down. Failing that request
// would fail the agent's turn, so an unknown session is accepted silently.
func TestHookNotifyUnknownSessionSucceedsWithoutBroadcast(t *testing.T) {
	h := newHookServer(t)
	rec := h.post(t, "no-such-session", `{"title":"Claude","body":"Turn complete"}`, h.token(), "")
	if rec.Code < 200 || rec.Code > 299 {
		t.Fatalf("status = %d, want success; body = %s", rec.Code, rec.Body.String())
	}
	if msg := nextNotifyFrame(t, h.conn); msg != nil {
		t.Fatalf("unknown session broadcast a frame: %#v", msg)
	}
}

func TestHookNotifyRejectsBlankReport(t *testing.T) {
	h := newHookServer(t)
	for _, body := range []string{`{}`, `{"title":"","body":""}`, `{"title":"  ","body":"\t"}`} {
		rec := h.post(t, h.sess.ID, body, h.token(), "")
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body %s: status = %d, want 400", body, rec.Code)
		}
		if msg := nextNotifyFrame(t, h.conn); msg != nil {
			t.Fatalf("body %s broadcast a frame: %#v", body, msg)
		}
	}
}

func TestHookNotifyRequiresToken(t *testing.T) {
	h := newHookServer(t)
	rec := h.post(t, h.sess.ID, `{"title":"Claude","body":"Turn complete"}`, "", "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if msg := nextNotifyFrame(t, h.conn); msg != nil {
		t.Fatalf("unauthenticated request broadcast a frame: %#v", msg)
	}
}

func TestHookNotifyRejectsForeignOrigin(t *testing.T) {
	h := newHookServer(t)
	rec := h.post(t, h.sess.ID, `{"title":"Claude","body":"Turn complete"}`, h.token(), "http://evil.example")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
	if msg := nextNotifyFrame(t, h.conn); msg != nil {
		t.Fatalf("foreign origin broadcast a frame: %#v", msg)
	}
}
