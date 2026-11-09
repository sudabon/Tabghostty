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
)

func TestPatchSessionMemoSuccess(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	changed := false
	manager.SetHooks(func() { changed = true }, nil, nil, nil)
	srv := &Server{hub: &Hub{manager: manager}}

	req := httptest.NewRequest(http.MethodPatch, "/api/sessions/"+s.ID, strings.NewReader(`{"memo":" CI watch "}`))
	req.SetPathValue("id", s.ID)
	rec := httptest.NewRecorder()
	srv.handlePatchSession(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var info session.Info
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info.Memo != "CI watch" {
		t.Fatalf("memo = %q, want CI watch", info.Memo)
	}
	if !changed {
		t.Fatal("expected sessions broadcast hook to run")
	}
}

func TestPatchSessionMemoRejectsOverLimit(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_ = s.SetMemo("keep")
	srv := &Server{hub: &Hub{manager: manager}}

	tooLong := `{"memo":"` + strings.Repeat("あ", session.MaxMemoRunes+1) + `"}`
	req := httptest.NewRequest(http.MethodPatch, "/api/sessions/"+s.ID, strings.NewReader(tooLong))
	req.SetPathValue("id", s.ID)
	rec := httptest.NewRecorder()
	srv.handlePatchSession(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
	if got := s.Info().Memo; got != "keep" {
		t.Fatalf("memo = %q, want keep", got)
	}
}

func TestPatchSessionMemoUnknownID(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	srv := &Server{hub: &Hub{manager: manager}}

	req := httptest.NewRequest(http.MethodPatch, "/api/sessions/missing", strings.NewReader(`{"memo":"x"}`))
	req.SetPathValue("id", "missing")
	rec := httptest.NewRecorder()
	srv.handlePatchSession(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}

func patchSession(t *testing.T, srv *Server, id, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPatch, "/api/sessions/"+id, strings.NewReader(body))
	req.SetPathValue("id", id)
	rec := httptest.NewRecorder()
	srv.handlePatchSession(rec, req)
	return rec
}

func TestPatchSessionNotificationsMutedLeavesMemo(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	_ = s.SetMemo("CI watch")
	changed := false
	manager.SetHooks(func() { changed = true }, nil, nil, nil)
	srv := &Server{hub: &Hub{manager: manager}}

	rec := patchSession(t, srv, s.ID, `{"notifications_muted":true}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var info session.Info
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if !info.NotificationsMuted || info.Memo != "CI watch" {
		t.Fatalf("info = muted %v memo %q, want true / CI watch", info.NotificationsMuted, info.Memo)
	}
	if !changed {
		t.Fatal("expected sessions broadcast hook to run")
	}

	listRec := httptest.NewRecorder()
	srv.handleListSessions(listRec, httptest.NewRequest(http.MethodGet, "/api/sessions", nil))
	if !strings.Contains(listRec.Body.String(), `"notifications_muted":true`) {
		t.Fatalf("list body = %s, want notifications_muted true", listRec.Body.String())
	}
}

func TestPatchSessionInvalidMemoDoesNotApplyMute(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	srv := &Server{hub: &Hub{manager: manager}}

	body := `{"memo":"` + strings.Repeat("あ", session.MaxMemoRunes+1) + `","notifications_muted":true}`
	rec := patchSession(t, srv, s.ID, body)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
	if s.Info().NotificationsMuted {
		t.Fatal("mute must not apply when memo is rejected")
	}
}

func TestPatchSessionRejectsEmptyAndWrongType(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	srv := &Server{hub: &Hub{manager: manager}}

	for _, body := range []string{`{}`, `{"notifications_muted":"yes"}`, `{"memo":1}`} {
		rec := patchSession(t, srv, s.ID, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body %s: status = %d, want %d", body, rec.Code, http.StatusBadRequest)
		}
	}
	if s.Info().NotificationsMuted {
		t.Fatal("session should stay unmuted")
	}
}

func TestCreatedSessionIsNotMuted(t *testing.T) {
	store := testConfigStore(t)
	manager := session.NewManager(store, log.New(io.Discard, "", 0))
	defer manager.Close()
	s, err := manager.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(manager.SessionInfo(s))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"notifications_muted":false`) {
		t.Fatalf("session payload = %s, want notifications_muted false", raw)
	}
}
