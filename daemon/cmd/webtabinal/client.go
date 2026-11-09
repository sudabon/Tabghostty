package main

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
)

const daemonHTTPTimeout = 5 * time.Second

// daemonClient talks to an already-running daemon over its authenticated
// loopback API. No command built on it starts the daemon.
type daemonClient struct {
	baseURL string
	token   string
	client  *http.Client
}

func daemonClientFromConfig(cfg *config.Store, client *http.Client, timeout time.Duration) daemonClient {
	if client == nil {
		client = &http.Client{Timeout: timeout}
	}
	port := 8642
	token := ""
	if cfg != nil {
		port = cfg.Get().Port
		token = cfg.AuthToken()
	}
	return daemonClient{
		baseURL: "http://127.0.0.1:" + strconv.Itoa(port),
		token:   token,
		client:  client,
	}
}

// do issues an authenticated request. The Host header comes from baseURL
// because the daemon refuses any other host.
func (c daemonClient) do(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(c.baseURL, "/")+path, body)
	if err != nil {
		return nil, err
	}
	if u, err := url.Parse(c.baseURL); err == nil {
		req.Host = u.Host
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return c.client.Do(req)
}
