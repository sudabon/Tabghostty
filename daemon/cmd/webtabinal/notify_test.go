package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseNotifyArgsExplicitSessionWins(t *testing.T) {
	opts, err := parseNotifyArgs([]string{"--session", "chosen", "--title", "Claude Code", "--body", "Turn complete", "--kind", "agent_blocked"}, "from-env")
	if err != nil {
		t.Fatal(err)
	}
	if opts.SessionID != "chosen" {
		t.Fatalf("session = %q, want the explicit value", opts.SessionID)
	}
	if opts.Title != "Claude Code" || opts.Body != "Turn complete" || opts.Kind != "agent_blocked" {
		t.Fatalf("%+v", opts)
	}
}

func TestParseNotifyArgsFallsBackToEnvironment(t *testing.T) {
	opts, err := parseNotifyArgs(nil, "from-env")
	if err != nil {
		t.Fatal(err)
	}
	if opts.SessionID != "from-env" {
		t.Fatalf("session = %q, want the environment value", opts.SessionID)
	}
	if opts.Title == "" || opts.Body == "" {
		t.Fatalf("title/body must default to something reportable: %+v", opts)
	}
	if opts.Kind != "" {
		t.Fatalf("kind = %q, want empty so the daemon applies its default", opts.Kind)
	}
}

// A hook may fire outside a WebTabinal session. That is not a usage error; the
// command simply has nothing to report.
func TestParseNotifyArgsWithoutAnySessionIsNotAnError(t *testing.T) {
	opts, err := parseNotifyArgs(nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if opts.SessionID != "" {
		t.Fatalf("session = %q, want empty", opts.SessionID)
	}
}

func TestParseNotifyArgsRejectsBadUsage(t *testing.T) {
	for _, args := range [][]string{
		{"--nope"},
		{"--title"},
		{"--body"},
		{"--kind"},
		{"--session"},
		{"positional"},
	} {
		if _, err := parseNotifyArgs(args, "from-env"); err == nil {
			t.Fatalf("args %v: expected a usage error", args)
		}
	}
}

func TestParseNotifyArgsTrimsSurroundingSpace(t *testing.T) {
	opts, err := parseNotifyArgs([]string{"--session", "  s1  ", "--kind", " agent_idle "}, "")
	if err != nil {
		t.Fatal(err)
	}
	if opts.SessionID != "s1" || opts.Kind != "agent_idle" {
		t.Fatalf("%+v", opts)
	}
}

func TestNotifyPostsReport(t *testing.T) {
	var gotPath, gotAuth, gotBody string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		gotBody = string(raw)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer ts.Close()

	var out, errBuf strings.Builder
	code := runNotifyClient(&out, &errBuf, daemonClient{baseURL: ts.URL, token: "secret-token", client: ts.Client()},
		notifyOptions{SessionID: "s1", Title: "Claude Code", Body: "Turn complete", Kind: "agent_idle"})
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if gotPath != "/api/sessions/s1/notify" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotAuth != "Bearer secret-token" {
		t.Fatalf("authorization = %q", gotAuth)
	}
	var payload map[string]string
	if err := json.Unmarshal([]byte(gotBody), &payload); err != nil {
		t.Fatalf("body %q: %v", gotBody, err)
	}
	if payload["title"] != "Claude Code" || payload["body"] != "Turn complete" || payload["kind"] != "agent_idle" {
		t.Fatalf("payload = %#v", payload)
	}
	if out.String() != "" || errBuf.String() != "" {
		t.Fatalf("stdout = %q stderr = %q, want silence", out.String(), errBuf.String())
	}
}

func TestNotifyOmitsBlankKind(t *testing.T) {
	var gotBody string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		gotBody = string(raw)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer ts.Close()

	var out, errBuf strings.Builder
	runNotifyClient(&out, &errBuf, daemonClient{baseURL: ts.URL, token: "t", client: ts.Client()},
		notifyOptions{SessionID: "s1", Title: "Agent", Body: "Turn complete"})
	if strings.Contains(gotBody, "kind") {
		t.Fatalf("body = %q, want no kind field so the daemon defaults it", gotBody)
	}
}

// A stop hook that exits non-zero blocks the agent's turn on both Claude Code
// and cursor-agent. Every failure mode below must therefore stay silent and
// successful.
func TestNotifyStaysSilentAndSuccessfulOnFailure(t *testing.T) {
	closed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	closedURL := closed.URL
	closedClient := closed.Client()
	closed.Close()

	broken := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer broken.Close()

	unauthorized := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}))
	defer unauthorized.Close()

	cases := []struct {
		name   string
		client daemonClient
		opts   notifyOptions
	}{
		{
			name:   "daemon not listening",
			client: daemonClient{baseURL: closedURL, token: "t", client: closedClient},
			opts:   notifyOptions{SessionID: "s1", Title: "Agent", Body: "Turn complete"},
		},
		{
			name:   "no session could be determined",
			client: daemonClient{baseURL: broken.URL, token: "t", client: broken.Client()},
			opts:   notifyOptions{Title: "Agent", Body: "Turn complete"},
		},
		{
			name:   "daemon returns a server error",
			client: daemonClient{baseURL: broken.URL, token: "t", client: broken.Client()},
			opts:   notifyOptions{SessionID: "s1", Title: "Agent", Body: "Turn complete"},
		},
		{
			name:   "token is stale",
			client: daemonClient{baseURL: unauthorized.URL, token: "t", client: unauthorized.Client()},
			opts:   notifyOptions{SessionID: "s1", Title: "Agent", Body: "Turn complete"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out, errBuf strings.Builder
			if code := runNotifyClient(&out, &errBuf, tc.client, tc.opts); code != 0 {
				t.Fatalf("exit %d, want 0", code)
			}
			if out.String() != "" || errBuf.String() != "" {
				t.Fatalf("stdout = %q stderr = %q, want silence", out.String(), errBuf.String())
			}
		})
	}
}

// Without a session there is nothing to report, so the daemon is never called.
func TestNotifyWithoutSessionSkipsTheRequest(t *testing.T) {
	called := false
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusNoContent)
	}))
	defer ts.Close()

	var out, errBuf strings.Builder
	runNotifyClient(&out, &errBuf, daemonClient{baseURL: ts.URL, token: "t", client: ts.Client()},
		notifyOptions{Title: "Agent", Body: "Turn complete"})
	if called {
		t.Fatal("a sessionless report must not reach the daemon")
	}
}
