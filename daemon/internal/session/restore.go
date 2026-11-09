package session

import (
	"log"
	"time"
)

const (
	// readyPollInterval is how often a restored session is checked for its
	// prompt. Short enough that the command lands the moment the shell is
	// ready, cheap enough to run per restored tab.
	readyPollInterval = 25 * time.Millisecond
	// readyPollTimeout bounds the wait. A shell without WebTabinal integration
	// never reports a prompt, so the command goes in once this elapses.
	readyPollTimeout = 2000 * time.Millisecond
)

// CreateRestored creates a session at cwd carrying memo. It exists so restore
// can reproduce a recorded tab in one step; everything else about the session
// is identical to a user-created one.
func (m *Manager) CreateRestored(cwd, memo string) (*Session, error) {
	s, err := m.Create(cwd)
	if err != nil {
		return nil, err
	}
	if memo != "" {
		// A memo that was valid when it was stored stays valid; a rejected one
		// must not cost us the restored tab.
		if err := s.SetMemo(memo); err != nil && m.logger != nil {
			m.logger.Printf("restore: session %s memo: %v", s.ID, err)
		}
	}
	return s, nil
}

// SendWhenReady schedules input to be written to s exactly once, after its
// shell reports a prompt or after a bounded fallback wait. It returns
// immediately; the wait happens on its own goroutine.
func (m *Manager) SendWhenReady(s *Session, input string) {
	if s == nil || input == "" {
		return
	}
	go sendWhenReady(s, input, readyPollInterval, readyPollTimeout, m.logger)
}

// sendWhenReady polls until the shell is ready, then writes input once.
//
// Readiness is PromptSeen — OSC 133;A, i.e. the shell actually printed a
// prompt — rather than merely leaving the `starting` state. The integration
// emits OSC 7 while the startup files are still running, which clears
// `starting` before the shell is at a prompt; waiting for the prompt keeps the
// command out of a half-initialised shell. A shell with no integration reports
// neither, and the timeout covers it.
func sendWhenReady(s *Session, input string, poll, timeout time.Duration, logger *log.Logger) {
	deadline := time.Now().Add(timeout)
	for {
		info := s.Info()
		if info.State == StateExited {
			// Nothing to type into, and no tab the user would expect it in.
			return
		}
		if info.PromptSeen || !time.Now().Before(deadline) {
			break
		}
		time.Sleep(poll)
	}
	if err := s.Write([]byte(input)); err != nil && logger != nil {
		logger.Printf("restore: session %s write resume command: %v", s.ID, err)
	}
}
