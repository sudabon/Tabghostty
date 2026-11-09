package server

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/imagedrop"
	"github.com/sudabon/webtabinal/internal/paths"
)

const (
	cookieName            = "webtabinal_token"
	contentSecurityPolicy = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; frame-ancestors 'none'; style-src 'self' 'unsafe-inline'"
)

var ErrAlreadyRunning = errors.New("webtabinal is already listening")

type Server struct {
	cfg       *config.Store
	logger    *log.Logger
	mux       *http.ServeMux
	hub       *Hub
	images    *imagedrop.Store
	boundPort int
}

// SetImageStore installs the directory that pasted and dropped images are
// written to. Without one the image endpoint reports 503 rather than guessing
// a location, which keeps tests and headless callers off the real support dir.
func (s *Server) SetImageStore(store *imagedrop.Store) { s.images = store }

func New(cfg *config.Store, logger *log.Logger, hub *Hub, static http.Handler) *Server {
	s := &Server{cfg: cfg, logger: logger, mux: http.NewServeMux(), hub: hub, boundPort: cfg.Get().Port}
	s.routes(static)
	return s
}

func (s *Server) Handler() http.Handler {
	return s.withSecurity(s.mux)
}

func (s *Server) ListenAndServe() error {
	return s.Run(context.Background())
}

// LoopbackListening reports whether WebTabinal is already serving on 127.0.0.1:port.
func LoopbackListening(port int) bool {
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	client := &http.Client{
		Timeout: 300 * time.Millisecond,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Get("http://" + addr + "/api/config")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized ||
		resp.Header.Get("X-Frame-Options") != "DENY" ||
		resp.Header.Get("X-Content-Type-Options") != "nosniff" ||
		resp.Header.Get("Content-Security-Policy") != contentSecurityPolicy {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	return err == nil && string(body) == "unauthorized\n"
}

func (s *Server) Run(ctx context.Context) error {
	s.boundPort = s.cfg.Get().Port
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(s.boundPort))
	if LoopbackListening(s.boundPort) {
		s.logger.Printf("already listening on http://%s; exiting successfully", addr)
		return ErrAlreadyRunning
	}
	s.logger.Printf("listening on http://%s", addr)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           s.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	result := make(chan error, 1)
	go func() {
		result <- httpServer.ListenAndServe()
	}()
	select {
	case err := <-result:
		return s.normalizeListenError(addr, err)
	case <-ctx.Done():
		shutdownErr := httpServer.Shutdown(context.Background())
		err := <-result
		if shutdownErr != nil {
			return shutdownErr
		}
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func (s *Server) normalizeListenError(addr string, err error) error {
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	if errors.Is(err, syscall.EADDRINUSE) && LoopbackListening(s.boundPort) {
		s.logger.Printf("already listening on http://%s after bind race; exiting successfully", addr)
		return ErrAlreadyRunning
	}
	return err
}

func (s *Server) withSecurity(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", contentSecurityPolicy)

		port := strconv.Itoa(s.boundPort)
		hostOK := r.Host == "127.0.0.1:"+port || r.Host == "localhost:"+port
		if !hostOK {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if origin := r.Header.Get("Origin"); origin != "" {
			ok := origin == "http://127.0.0.1:"+port || origin == "http://localhost:"+port
			if !ok {
				http.Error(w, "forbidden origin", http.StatusForbidden)
				return
			}
		}

		if r.Method == http.MethodGet && !strings.HasPrefix(r.URL.Path, "/api") {
			s.setAuthCookie(w)
			next.ServeHTTP(w, r)
			return
		}

		if strings.HasPrefix(r.URL.Path, "/api") {
			if !s.validToken(r) {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) setAuthCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    s.cfg.AuthToken(),
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	})
}

func (s *Server) validToken(r *http.Request) bool {
	if c, err := r.Cookie(cookieName); err == nil && subtle.ConstantTimeCompare([]byte(c.Value), []byte(s.cfg.AuthToken())) == 1 {
		return true
	}
	auth := r.Header.Get("Authorization")
	if strings.HasPrefix(auth, "Bearer ") {
		return subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(auth, "Bearer ")), []byte(s.cfg.AuthToken())) == 1
	}
	return false
}

func (s *Server) routes(static http.Handler) {
	s.mux.HandleFunc("GET /api/sessions", s.handleListSessions)
	s.mux.HandleFunc("POST /api/sessions", s.handleCreateSession)
	s.mux.HandleFunc("POST /api/sessions/{id}/duplicate", s.handleDuplicateSession)
	s.mux.HandleFunc("POST /api/sessions/{id}/restart", s.handleRestartSession)
	s.mux.HandleFunc("PATCH /api/sessions/{id}", s.handlePatchSession)
	s.mux.HandleFunc("DELETE /api/sessions/{id}", s.handleDeleteSession)
	s.mux.HandleFunc("PUT /api/sessions/order", s.handleReorderSessions)
	s.mux.HandleFunc("GET /api/sessions/{id}/state-snapshot", s.handleStateSnapshot)
	s.mux.HandleFunc("POST /api/sessions/{id}/notify", s.handleSessionNotify)
	s.mux.HandleFunc("POST /api/sessions/{id}/images", s.handleSessionImage)
	s.mux.HandleFunc("GET /api/config", s.handleGetConfig)
	s.mux.HandleFunc("PATCH /api/config", s.handlePatchConfig)
	s.mux.HandleFunc("GET /api/ws", s.hub.HandleWS)
	if static != nil {
		s.mux.Handle("/", static)
	} else {
		s.mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/plain")
			_, _ = w.Write([]byte(paths.AppName + " daemon is running.\n"))
		})
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
