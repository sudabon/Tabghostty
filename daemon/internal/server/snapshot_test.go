package server

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/session"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

func snapshotServer(t *testing.T) (*Server, *session.Manager, *bytesLogger) {
	t.Helper()
	store := testConfigStore(t)
	logs := &bytesLogger{}
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	hub := NewHub(mgr, store, log.New(io.Discard, "", 0))
	srv := New(store, log.New(logs, "", 0), hub, nil)
	return srv, mgr, logs
}

type bytesLogger struct {
	b strings.Builder
}

func (l *bytesLogger) Write(p []byte) (int, error) { return l.b.Write(p) }
func (l *bytesLogger) String() string              { return l.b.String() }

func snapshotRequest(t *testing.T, srv *Server, method, path string, token string, host, origin string) *httptest.ResponseRecorder {
	t.Helper()
	if host == "" {
		host = "127.0.0.1:8642"
	}
	req := httptest.NewRequest(method, "http://"+host+path, nil)
	req.Host = host
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	if token != "" {
		if strings.HasPrefix(token, "cookie:") {
			req.AddCookie(&http.Cookie{Name: cookieName, Value: strings.TrimPrefix(token, "cookie:")})
		} else {
			req.Header.Set("Authorization", "Bearer "+token)
		}
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}

func TestStateSnapshotBearerSuccess(t *testing.T) {
	srv, mgr, logs := snapshotServer(t)
	s, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	rec := snapshotRequest(t, srv, http.MethodGet, "/api/sessions/"+s.ID+"/state-snapshot?lines=15&buffer=active", srv.cfg.AuthToken(), "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["session_id"] != s.ID {
		t.Fatalf("session_id = %#v", body["session_id"])
	}
	if body["model_available"] != true {
		t.Fatalf("model_available = %#v", body["model_available"])
	}
	lines, _ := body["lines"].([]any)
	if len(lines) > 15 {
		t.Fatalf("lines = %d, want <= 15", len(lines))
	}
	if rec.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("content-type = %s", rec.Header().Get("Content-Type"))
	}
	if strings.Contains(logs.String(), srv.cfg.AuthToken()) {
		t.Fatal("bearer token logged")
	}
	for _, line := range lines {
		if s, ok := line.(string); ok && s != "" && strings.Contains(logs.String(), s) && len(s) > 4 {
			t.Fatalf("screen line logged: %q", s)
		}
	}
}

func TestStateSnapshotCookieSuccess(t *testing.T) {
	srv, mgr, _ := snapshotServer(t)
	s, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	rec := snapshotRequest(t, srv, http.MethodGet, "/api/sessions/"+s.ID+"/state-snapshot", "cookie:"+srv.cfg.AuthToken(), "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
}

func TestStateSnapshotAuthAndHost(t *testing.T) {
	srv, mgr, logs := snapshotServer(t)
	s, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	path := "/api/sessions/" + s.ID + "/state-snapshot"
	if rec := snapshotRequest(t, srv, http.MethodGet, path, "", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("missing auth = %d", rec.Code)
	}
	if rec := snapshotRequest(t, srv, http.MethodGet, path, "nope", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("bad bearer = %d", rec.Code)
	}
	if rec := snapshotRequest(t, srv, http.MethodGet, path, srv.cfg.AuthToken(), "example.com", ""); rec.Code != http.StatusForbidden {
		t.Fatalf("foreign host = %d", rec.Code)
	}
	if rec := snapshotRequest(t, srv, http.MethodGet, path, srv.cfg.AuthToken(), "", "http://evil.example"); rec.Code != http.StatusForbidden {
		t.Fatalf("foreign origin = %d", rec.Code)
	}
	if strings.Contains(logs.String(), srv.cfg.AuthToken()) {
		t.Fatal("token logged on auth failure")
	}
}

func TestStateSnapshotQueryValidation(t *testing.T) {
	srv, mgr, _ := snapshotServer(t)
	s, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	token := srv.cfg.AuthToken()
	before := mgr.SessionInfo(s)
	path := "/api/sessions/" + s.ID + "/state-snapshot"
	for _, q := range []string{"?lines=0", "?lines=201", "?lines=foo", "?buffer=scrollback"} {
		rec := snapshotRequest(t, srv, http.MethodGet, path+q, token, "", "")
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s status = %d", q, rec.Code)
		}
	}
	after := mgr.SessionInfo(s)
	if before.Command != after.Command || before.State != after.State || before.Memo != after.Memo {
		t.Fatal("invalid query mutated session")
	}
}

func TestStateSnapshotUnknownSession(t *testing.T) {
	srv, _, _ := snapshotServer(t)
	rec := snapshotRequest(t, srv, http.MethodGet, "/api/sessions/missing/state-snapshot", srv.cfg.AuthToken(), "", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d", rec.Code)
	}
}

func TestStateSnapshotUnavailableModel(t *testing.T) {
	srv, mgr, logs := snapshotServer(t)
	s, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s.MarkScreenUnavailable()
	rec := snapshotRequest(t, srv, http.MethodGet, "/api/sessions/"+s.ID+"/state-snapshot", srv.cfg.AuthToken(), "", "")
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["error"] != "screen_unavailable" {
		t.Fatalf("body = %#v", body)
	}
	if _, ok := body["lines"]; ok {
		t.Fatal("unavailable response included lines")
	}
	if strings.Contains(logs.String(), "screen_unavailable") && strings.Contains(logs.String(), "\x1b") {
		t.Fatal("logs contained screen bytes")
	}
}

func TestStateSnapshotIsReadOnly(t *testing.T) {
	srv, mgr, _ := snapshotServer(t)
	s, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	beforeInfo := mgr.SessionInfo(s)
	beforeSnap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: 24})
	rec := snapshotRequest(t, srv, http.MethodGet, "/api/sessions/"+s.ID+"/state-snapshot?lines=8", srv.cfg.AuthToken(), "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	afterInfo := mgr.SessionInfo(s)
	afterSnap := s.ScreenSnapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: 24})
	if beforeInfo.Command != afterInfo.Command || beforeInfo.State != afterInfo.State || beforeInfo.AgentState != afterInfo.AgentState {
		t.Fatalf("session mutated: %+v -> %+v", beforeInfo, afterInfo)
	}
	if strings.Join(beforeSnap.Lines, "\n") != strings.Join(afterSnap.Lines, "\n") {
		t.Fatal("screen contents changed")
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if lines, ok := body["lines"].([]any); ok && len(lines) > 8 {
		t.Fatalf("line bound not enforced: %d", len(lines))
	}
}
