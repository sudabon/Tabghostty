package server

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/imagedrop"
	"github.com/sudabon/webtabinal/internal/session"
)

type imageServer struct {
	srv  *Server
	sess *session.Session
	dir  string
}

func newImageServer(t *testing.T, withStore bool) *imageServer {
	t.Helper()
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	hub := NewHub(mgr, store, log.New(io.Discard, "", 0))
	srv := New(store, log.New(io.Discard, "", 0), hub, nil)
	dir := filepath.Join(t.TempDir(), "images")
	if withStore {
		srv.SetImageStore(imagedrop.New(dir))
	}
	sess, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return &imageServer{srv: srv, sess: sess, dir: dir}
}

func (s *imageServer) post(t *testing.T, sessionID string, body []byte, token string) *httptest.ResponseRecorder {
	t.Helper()
	host := "127.0.0.1:8642"
	req := httptest.NewRequest(http.MethodPost, "http://"+host+"/api/sessions/"+sessionID+"/images", bytes.NewReader(body))
	req.Host = host
	req.Header.Set("Content-Type", "application/octet-stream")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	s.srv.Handler().ServeHTTP(rec, req)
	return rec
}

func onePixelPNG() []byte {
	return []byte{
		0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
		0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R',
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
		0x89, 0x00, 0x00, 0x00, 0x0a, 'I', 'D', 'A', 'T',
		0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
		0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00,
		0x00, 0x00, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82,
	}
}

func TestImageUploadReturnsPathOnDisk(t *testing.T) {
	s := newImageServer(t, true)
	png := onePixelPNG()
	rec := s.post(t, s.sess.ID, png, s.srv.cfg.AuthToken())
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201: %s", rec.Code, rec.Body.String())
	}
	var got imagedrop.Saved
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.MIME != "image/png" {
		t.Errorf("mime = %s, want image/png", got.MIME)
	}
	if got.Bytes != len(png) {
		t.Errorf("bytes = %d, want %d", got.Bytes, len(png))
	}
	if filepath.Dir(got.Path) != s.dir {
		t.Errorf("path = %s, want it under %s", got.Path, s.dir)
	}
	on, err := os.ReadFile(got.Path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !bytes.Equal(on, png) {
		t.Error("stored bytes differ from the upload")
	}
}

// The path is typed straight into the PTY, so a name needing shell quoting
// would put the burden on every caller. Save must not generate one.
func TestImageUploadNameNeedsNoShellQuoting(t *testing.T) {
	s := newImageServer(t, true)
	rec := s.post(t, s.sess.ID, onePixelPNG(), s.srv.cfg.AuthToken())
	var got imagedrop.Saved
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if strings.ContainsAny(got.Name, " \t'\"\\$`&|;<>()*?[]{}!#~") {
		t.Fatalf("generated name %q contains a character that needs shell quoting", got.Name)
	}
}

func TestImageUploadRejectsNonImage(t *testing.T) {
	s := newImageServer(t, true)
	rec := s.post(t, s.sess.ID, []byte("#!/bin/sh\necho hi\n"), s.srv.cfg.AuthToken())
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 415", rec.Code)
	}
	if entries, err := os.ReadDir(s.dir); err == nil && len(entries) != 0 {
		t.Fatalf("rejected upload left %d files behind", len(entries))
	}
}

func TestImageUploadRejectsOversize(t *testing.T) {
	s := newImageServer(t, true)
	big := append(onePixelPNG(), make([]byte, imagedrop.MaxBytes)...)
	rec := s.post(t, s.sess.ID, big, s.srv.cfg.AuthToken())
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413", rec.Code)
	}
}

func TestImageUploadRequiresKnownSession(t *testing.T) {
	s := newImageServer(t, true)
	rec := s.post(t, "no-such-session", onePixelPNG(), s.srv.cfg.AuthToken())
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}

func TestImageUploadRequiresAuth(t *testing.T) {
	s := newImageServer(t, true)
	rec := s.post(t, s.sess.ID, onePixelPNG(), "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
	if entries, err := os.ReadDir(s.dir); err == nil && len(entries) != 0 {
		t.Fatalf("unauthenticated upload wrote %d files", len(entries))
	}
}

func TestImageUploadWithoutStoreIsUnavailable(t *testing.T) {
	s := newImageServer(t, false)
	rec := s.post(t, s.sess.ID, onePixelPNG(), s.srv.cfg.AuthToken())
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}
