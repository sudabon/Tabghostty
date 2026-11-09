package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/paths"
)

type snapshotOptions struct {
	SessionID string
	Lines     int
	Buffer    string
	JSON      bool
}

func parseStateArgs(args []string) (snapshotOptions, error) {
	var opts snapshotOptions
	opts.Lines = 15
	opts.Buffer = "active"
	if len(args) < 2 || args[0] != "snapshot" {
		return opts, fmt.Errorf("usage: %s state snapshot <session-id> [--lines N] [--buffer active|primary|alternate] [--json]", paths.CLIName)
	}
	opts.SessionID = args[1]
	if strings.TrimSpace(opts.SessionID) == "" || strings.HasPrefix(opts.SessionID, "-") {
		return opts, fmt.Errorf("session-id is required")
	}
	for i := 2; i < len(args); i++ {
		switch args[i] {
		case "--json":
			opts.JSON = true
		case "--lines":
			if i+1 >= len(args) {
				return opts, fmt.Errorf("--lines requires a value")
			}
			i++
			n, err := strconv.Atoi(args[i])
			if err != nil || n < 1 || n > 200 {
				return opts, fmt.Errorf("lines must be an integer from 1 to 200")
			}
			opts.Lines = n
		case "--buffer":
			if i+1 >= len(args) {
				return opts, fmt.Errorf("--buffer requires a value")
			}
			i++
			switch args[i] {
			case "active", "primary", "alternate":
				opts.Buffer = args[i]
			default:
				return opts, fmt.Errorf("buffer must be active, primary, or alternate")
			}
		default:
			return opts, fmt.Errorf("unknown option %s", args[i])
		}
	}
	return opts, nil
}

func (c daemonClient) fetch(ctx context.Context, opts snapshotOptions) ([]byte, int, error) {
	q := url.Values{}
	q.Set("lines", strconv.Itoa(opts.Lines))
	q.Set("buffer", opts.Buffer)
	resp, err := c.do(ctx, http.MethodGet, "/api/sessions/"+url.PathEscape(opts.SessionID)+"/state-snapshot?"+q.Encode(), nil)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, resp.StatusCode, err
	}
	return body, resp.StatusCode, nil
}

func runStateSnapshot(wOut, wErr io.Writer, cfg *config.Store, client *http.Client, opts snapshotOptions) int {
	return runStateSnapshotClient(wOut, wErr, daemonClientFromConfig(cfg, client, daemonHTTPTimeout), opts)
}

func runStateSnapshotClient(wOut, wErr io.Writer, c daemonClient, opts snapshotOptions) int {
	ctx, cancel := context.WithTimeout(context.Background(), daemonHTTPTimeout)
	defer cancel()
	body, status, err := c.fetch(ctx, opts)
	if err != nil {
		fmt.Fprintf(wErr, "cannot reach WebTabinal daemon at %s: %v\n", c.baseURL, err)
		fmt.Fprintf(wErr, "start the daemon first (this command does not start it).\n")
		return 1
	}
	switch status {
	case http.StatusOK:
		if opts.JSON {
			out := bytes.TrimSpace(body)
			if !json.Valid(out) {
				fmt.Fprintf(wErr, "daemon returned invalid JSON (rebuild and restart webtabinal if this binary is newer than the running daemon)\n")
				return 1
			}
			fmt.Fprintf(wOut, "%s\n", out)
			return 0
		}
		if err := writeHumanSnapshot(wOut, body); err != nil {
			fmt.Fprintf(wErr, "%v\n", err)
			return 1
		}
		return 0
	case http.StatusUnauthorized, http.StatusForbidden:
		fmt.Fprintf(wErr, "authentication failed (HTTP %d)\n", status)
		return 1
	case http.StatusNotFound:
		fmt.Fprintf(wErr, "session not found: %s\n", opts.SessionID)
		return 1
	case http.StatusConflict:
		fmt.Fprintf(wErr, "screen model is unavailable for session %s\n", opts.SessionID)
		return 1
	case http.StatusBadRequest:
		fmt.Fprintf(wErr, "invalid snapshot request: %s\n", strings.TrimSpace(string(body)))
		return 1
	default:
		fmt.Fprintf(wErr, "snapshot failed: HTTP %d\n", status)
		return 1
	}
}

func writeHumanSnapshot(w io.Writer, raw []byte) error {
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		return err
	}
	fmt.Fprintf(w, "session: %v\n", doc["session_id"])
	fmt.Fprintf(w, "buffer: %v  %vx%v\n", doc["buffer"], doc["cols"], doc["rows"])
	fmt.Fprintf(w, "model: %s  detector: %s\n", boolWord(doc["model_available"]), boolWord(doc["detector_available"]))
	agent, _ := doc["agent"].(map[string]any)
	if agent != nil {
		fmt.Fprintf(w, "agent: %v  state: %v  signal: %v  since: %v\n", agent["id"], agent["state"], agent["signal"], agent["since"])
	}
	man, _ := doc["manifest"].(map[string]any)
	if man != nil {
		fmt.Fprintf(w, "manifest: %v  verified: %v  osc_authoritative: %v\n", man["id"], man["verified_against"], man["osc_authoritative"])
	}
	matches, _ := doc["matches"].(map[string]any)
	fmt.Fprintf(w, "matches:\n")
	for _, key := range []string{"blocked", "working", "idle"} {
		fmt.Fprintf(w, "  %s:", key)
		list, _ := matches[key].([]any)
		if len(list) == 0 {
			fmt.Fprintf(w, " (none)\n")
			continue
		}
		fmt.Fprintln(w)
		for _, item := range list {
			m, _ := item.(map[string]any)
			fmt.Fprintf(w, "    %v @ line %v\n", m["id"], m["line"])
		}
	}
	fmt.Fprintf(w, "lines:\n")
	lines, _ := doc["lines"].([]any)
	for _, line := range lines {
		fmt.Fprintf(w, "  | %v\n", line)
	}
	return nil
}

func boolWord(v any) string {
	if b, ok := v.(bool); ok && b {
		return "available"
	}
	return "unavailable"
}
