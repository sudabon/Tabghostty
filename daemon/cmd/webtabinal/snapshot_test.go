package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseStateArgs(t *testing.T) {
	opts, err := parseStateArgs([]string{"snapshot", "abc", "--lines", "20", "--buffer", "alternate", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.SessionID != "abc" || opts.Lines != 20 || opts.Buffer != "alternate" || !opts.JSON {
		t.Fatalf("%+v", opts)
	}
	if _, err := parseStateArgs([]string{"snapshot"}); err == nil {
		t.Fatal("expected missing id")
	}
	if _, err := parseStateArgs([]string{"snapshot", "abc", "--lines", "0"}); err == nil {
		t.Fatal("expected bad lines")
	}
	if _, err := parseStateArgs([]string{"snapshot", "abc", "--buffer", "scrollback"}); err == nil {
		t.Fatal("expected bad buffer")
	}
	if _, err := parseStateArgs([]string{"open"}); err == nil {
		t.Fatal("expected usage error")
	}
}

func TestCLISnapshotJSONAndHuman(t *testing.T) {
	payload := map[string]any{
		"session_id":         "s1",
		"buffer":             "active",
		"cols":               80,
		"rows":               24,
		"lines":              []string{"hello"},
		"model_available":    true,
		"detector_available": true,
		"agent":              map[string]any{"id": "cursor-agent", "state": "idle", "signal": "screen"},
		"manifest":           map[string]any{"id": "cursor-agent", "verified_against": []string{"2026.08.11-e8db854"}, "osc_authoritative": false},
		"matches":            map[string]any{"blocked": []any{}, "working": []any{}, "idle": []any{map[string]any{"id": "prompt", "line": 0}}},
	}
	raw, _ := json.Marshal(payload)
	var got *http.Request
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cp := r.Clone(r.Context())
		got = cp
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(raw)
	}))
	defer ts.Close()
	sc := daemonClient{baseURL: ts.URL, token: "secret-token", client: ts.Client()}

	var out, errBuf strings.Builder
	code := runStateSnapshotClient(&out, &errBuf, sc, snapshotOptions{SessionID: "s1", Lines: 15, Buffer: "active", JSON: true})
	if code != 0 {
		t.Fatalf("json exit %d stderr %s", code, errBuf.String())
	}
	if strings.TrimSpace(out.String()) != string(raw) && !json.Valid([]byte(strings.TrimSpace(out.String()))) {
		t.Fatalf("stdout not json: %s", out.String())
	}
	if strings.Contains(out.String(), "session:") {
		t.Fatal("json mode printed commentary")
	}

	out.Reset()
	errBuf.Reset()
	code = runStateSnapshotClient(&out, &errBuf, sc, snapshotOptions{SessionID: "s1", Lines: 8, Buffer: "primary", JSON: false})
	if code != 0 {
		t.Fatalf("human exit %d stderr %s", code, errBuf.String())
	}
	if !strings.Contains(out.String(), "session: s1") || !strings.Contains(out.String(), "| hello") {
		t.Fatalf("human output = %s", out.String())
	}
	if got == nil || got.Method != http.MethodGet {
		t.Fatalf("method = %v", got)
	}
	if got.Header.Get("Authorization") != "Bearer secret-token" {
		t.Fatalf("auth = %s", got.Header.Get("Authorization"))
	}
	if got.Header.Get("Origin") != "" {
		t.Fatal("origin was sent")
	}
	if got.URL.Path != "/api/sessions/s1/state-snapshot" {
		t.Fatalf("path = %s", got.URL.Path)
	}
	if got.URL.Query().Get("lines") != "8" || got.URL.Query().Get("buffer") != "primary" {
		t.Fatalf("query = %s", got.URL.RawQuery)
	}
}

func TestCLISnapshotDoesNotMutate(t *testing.T) {
	var methods []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"session_id":"s1","lines":[],"matches":{"blocked":[],"working":[],"idle":[]},"agent":{},"manifest":{}}`))
	}))
	defer ts.Close()
	sc := daemonClient{baseURL: ts.URL, token: "t", client: ts.Client()}
	code := runStateSnapshotClient(io.Discard, io.Discard, sc, snapshotOptions{SessionID: "s1", Lines: 15, Buffer: "active"})
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, m := range methods {
		if strings.HasPrefix(m, "POST") || strings.HasPrefix(m, "PATCH") || strings.HasPrefix(m, "PUT") || strings.HasPrefix(m, "DELETE") {
			t.Fatalf("mutation request: %s", m)
		}
		if strings.Contains(m, "/input") || strings.Contains(m, "/resize") {
			t.Fatalf("session mutation path: %s", m)
		}
	}
}

func TestCLISnapshotErrorStatuses(t *testing.T) {
	cases := []struct {
		status int
		want   string
	}{
		{http.StatusUnauthorized, "authentication failed"},
		{http.StatusNotFound, "session not found"},
		{http.StatusConflict, "unavailable"},
	}
	for _, tc := range cases {
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(`{"error":"x"}`))
		}))
		sc := daemonClient{baseURL: ts.URL, token: "t", client: ts.Client()}
		var out, errBuf strings.Builder
		code := runStateSnapshotClient(&out, &errBuf, sc, snapshotOptions{SessionID: "missing", Lines: 15, Buffer: "active"})
		ts.Close()
		if code == 0 {
			t.Fatalf("status %d succeeded", tc.status)
		}
		if out.Len() != 0 {
			t.Fatalf("stdout = %s", out.String())
		}
		if !strings.Contains(errBuf.String(), tc.want) {
			t.Fatalf("stderr = %s, want %s", errBuf.String(), tc.want)
		}
	}
}

func TestCLISnapshotDaemonUnavailable(t *testing.T) {
	sc := daemonClient{
		baseURL: "http://127.0.0.1:1",
		token:   "t",
		client:  &http.Client{Timeout: daemonHTTPTimeout},
	}
	var out, errBuf strings.Builder
	code := runStateSnapshotClient(&out, &errBuf, sc, snapshotOptions{SessionID: "s1", Lines: 15, Buffer: "active"})
	if code == 0 {
		t.Fatal("expected connection error")
	}
	if out.Len() != 0 {
		t.Fatalf("stdout = %s", out.String())
	}
	if !strings.Contains(errBuf.String(), "does not start") {
		t.Fatalf("stderr = %s", errBuf.String())
	}
}
