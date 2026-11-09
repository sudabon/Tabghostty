package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/paths"
)

// A stop hook runs in the agent's critical path, so the report gets a short
// leash: the daemon is on loopback and either answers at once or is not there.
const notifyHTTPTimeout = 2 * time.Second

// SessionEnvVar names the session that WebTabinal exports into every shell, and
// that a coding agent's hook processes therefore inherit.
const sessionEnvVar = "WEBTABINAL_SESSION_ID"

type notifyOptions struct {
	SessionID string
	Title     string
	Body      string
	// Kind is left empty unless asked for, so the daemon applies its default.
	Kind string
}

func notifyUsage() string {
	return fmt.Sprintf("usage: %s notify [--session ID] [--title TEXT] [--body TEXT] [--kind KIND]", paths.CLIName)
}

// parseNotifyArgs reads the report from flags, falling back to envSession for
// the session. A missing session is not a usage error: a hook can fire outside
// a WebTabinal session, and there is simply nothing to report then.
func parseNotifyArgs(args []string, envSession string) (notifyOptions, error) {
	opts := notifyOptions{
		SessionID: envSession,
		Title:     "Agent",
		Body:      "Turn complete",
	}
	for i := 0; i < len(args); i++ {
		target := map[string]*string{
			"--session": &opts.SessionID,
			"--title":   &opts.Title,
			"--body":    &opts.Body,
			"--kind":    &opts.Kind,
		}[args[i]]
		if target == nil {
			return opts, fmt.Errorf("unknown option %s\n%s", args[i], notifyUsage())
		}
		if i+1 >= len(args) {
			return opts, fmt.Errorf("%s requires a value\n%s", args[i], notifyUsage())
		}
		i++
		*target = args[i]
	}
	opts.SessionID = strings.TrimSpace(opts.SessionID)
	opts.Kind = strings.TrimSpace(opts.Kind)
	return opts, nil
}

func runNotify(wOut, wErr io.Writer, cfg *config.Store, client *http.Client, opts notifyOptions) int {
	return runNotifyClient(wOut, wErr, daemonClientFromConfig(cfg, client, notifyHTTPTimeout), opts)
}

// runNotifyClient always succeeds silently. A stop hook that exits non-zero
// blocks the agent's turn on both Claude Code and cursor-agent, and an
// undelivered notification is never worth stopping an agent over.
func runNotifyClient(wOut, wErr io.Writer, c daemonClient, opts notifyOptions) int {
	if opts.SessionID == "" {
		return 0
	}
	report := map[string]string{"title": opts.Title, "body": opts.Body}
	if opts.Kind != "" {
		report["kind"] = opts.Kind
	}
	payload, err := json.Marshal(report)
	if err != nil {
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), notifyHTTPTimeout)
	defer cancel()
	resp, err := c.do(ctx, http.MethodPost, "/api/sessions/"+url.PathEscape(opts.SessionID)+"/notify", bytes.NewReader(payload))
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	return 0
}
