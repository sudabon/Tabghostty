package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/sudabon/webtabinal/internal/imagedrop"
	"github.com/sudabon/webtabinal/internal/session"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

func (s *Server) handleListSessions(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"sessions": s.hub.manager.List()})
}

func (s *Server) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Cwd string `json:"cwd"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	sess, err := s.hub.manager.Create(body.Cwd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, s.hub.manager.SessionInfo(sess))
}

func (s *Server) handleDuplicateSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	sess, err := s.hub.manager.Duplicate(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, s.hub.manager.SessionInfo(sess))
}

func (s *Server) handleRestartSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	sess, err := s.hub.manager.Restart(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusOK, s.hub.manager.SessionInfo(sess))
}

func (s *Server) handlePatchSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var body struct {
		Memo               *string `json:"memo"`
		NotificationsMuted *bool   `json:"notifications_muted"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if body.Memo == nil && body.NotificationsMuted == nil {
		http.Error(w, "memo or notifications_muted is required", http.StatusBadRequest)
		return
	}
	sess, err := s.hub.manager.PatchSession(id, body.Memo, body.NotificationsMuted)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusOK, s.hub.manager.SessionInfo(sess))
}

func (s *Server) handleDeleteSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.hub.manager.Delete(id); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReorderSessions(w http.ResponseWriter, r *http.Request) {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.hub.manager.Reorder(body.IDs); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": s.hub.manager.List()})
}

func (s *Server) handleGetConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.cfg.Public())
}

func (s *Server) handlePatchConfig(w http.ResponseWriter, r *http.Request) {
	var patch map[string]any
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cfg, err := s.cfg.Patch(patch)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if s.hub != nil && s.hub.manager != nil {
		s.hub.manager.ApplyStateConfig(cfg.State)
	}
	writeJSON(w, http.StatusOK, cfg)
}

func (s *Server) handleStateSnapshot(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	lines, buf, err := parseSnapshotQuery(r)
	if err != nil {
		s.logSnapshot(id, http.StatusBadRequest)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if s.hub == nil || s.hub.manager == nil {
		s.logSnapshot(id, http.StatusNotFound)
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}
	diag, err := s.hub.manager.StateSnapshot(id, lines, buf)
	if err != nil {
		if errors.Is(err, session.ErrNotFound) {
			s.logSnapshot(id, http.StatusNotFound)
			http.Error(w, "session not found", http.StatusNotFound)
			return
		}
		if errors.Is(err, session.ErrScreenUnavailable) {
			s.logSnapshot(id, http.StatusConflict)
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":   "screen_unavailable",
				"message": "screen model is unavailable",
			})
			return
		}
		s.logSnapshot(id, http.StatusInternalServerError)
		http.Error(w, "snapshot failed", http.StatusInternalServerError)
		return
	}
	s.logSnapshot(id, http.StatusOK)
	writeJSON(w, http.StatusOK, diag)
}

func parseSnapshotQuery(r *http.Request) (int, vtscreen.BufferKind, error) {
	lines := 15
	if raw := strings.TrimSpace(r.URL.Query().Get("lines")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > 200 {
			return 0, "", errors.New("lines must be an integer from 1 to 200")
		}
		lines = n
	}
	buf := vtscreen.BufferActive
	if raw := strings.TrimSpace(r.URL.Query().Get("buffer")); raw != "" {
		switch vtscreen.BufferKind(raw) {
		case vtscreen.BufferActive, vtscreen.BufferPrimary, vtscreen.BufferAlternate:
			buf = vtscreen.BufferKind(raw)
		default:
			return 0, "", errors.New("buffer must be active, primary, or alternate")
		}
	}
	return lines, buf, nil
}

func (s *Server) logSnapshot(sessionID string, status int) {
	if s == nil || s.logger == nil {
		return
	}
	s.logger.Printf("state-snapshot session=%s status=%d", sessionID, status)
}

// handleSessionNotify accepts a turn-completion report from a coding agent's
// stop hook. A hook cannot reach the terminal, so this is the only path by
// which an agent's own account of its turn ending gets into the session.
func (s *Server) handleSessionNotify(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var body struct {
		Title string `json:"title"`
		Body  string `json:"body"`
		Kind  string `json:"kind"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.Title) == "" && strings.TrimSpace(body.Body) == "" {
		http.Error(w, "title or body is required", http.StatusBadRequest)
		return
	}
	kind := strings.TrimSpace(body.Kind)
	if kind == "" {
		kind = notifyKindAgentIdle
	}
	if s.hub != nil {
		s.hub.notifyFromHook(id, body.Title, body.Body, kind)
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleSessionImage stores an image the browser pasted or dropped and returns
// its path. The path is what actually reaches the agent: Claude Code, Codex,
// and cursor-agent all read an image from disk, so the client types this path
// into the PTY the way a native terminal inserts a dropped file's path.
func (s *Server) handleSessionImage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.images == nil {
		http.Error(w, "image store unavailable", http.StatusServiceUnavailable)
		return
	}
	if s.hub == nil || s.hub.manager == nil {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}
	if _, ok := s.hub.manager.Get(id); !ok {
		http.Error(w, "session not found", http.StatusNotFound)
		return
	}
	// One byte over the cap is enough to reject without buffering the rest.
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, imagedrop.MaxBytes+1))
	if err != nil {
		http.Error(w, "image exceeds size limit", http.StatusRequestEntityTooLarge)
		return
	}
	saved, err := s.images.Save(body)
	switch {
	case errors.Is(err, imagedrop.ErrTooLarge):
		http.Error(w, "image exceeds size limit", http.StatusRequestEntityTooLarge)
		return
	case errors.Is(err, imagedrop.ErrUnsupportedType):
		http.Error(w, "unsupported image type", http.StatusUnsupportedMediaType)
		return
	case err != nil:
		s.logger.Printf("session %s image save: %v", id, err)
		http.Error(w, "image save failed", http.StatusInternalServerError)
		return
	}
	s.logger.Printf("session-image session=%s name=%s bytes=%d", id, saved.Name, saved.Bytes)
	writeJSON(w, http.StatusCreated, saved)
}
