package session

import (
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/osc"
)

func TestHooksAreSynchronized(t *testing.T) {
	s := &Session{ID: "session", State: StateRunning}
	m := &Manager{sessions: map[string]*Session{s.ID: s}}
	noopChange := func() {}
	noopOutput := func(*Session, []byte) {}
	noopEvent := func(*Session, osc.Event) {}
	noopExit := func(*Session) {}
	m.SetHooks(noopChange, noopOutput, noopEvent, noopExit)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for range 1000 {
			m.SetHooks(noopChange, noopOutput, noopEvent, noopExit)
		}
	}()
	go func() {
		defer wg.Done()
		for range 1000 {
			s.mu.Lock()
			s.State = StateRunning
			s.mu.Unlock()
			m.pollFallback()
		}
	}()
	wg.Wait()
}

func TestCloseSynchronizesWithWait(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "sleep 10")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	s := &Session{cmd: cmd, done: make(chan struct{})}
	waited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(s.done)
		close(waited)
	}()

	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	<-waited
}

func TestRestartKeepsExitedSessionWhenReplacementFails(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := filepath.Join(home, "Library", "Application Support", "WebTabinal")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(configDir, "config.json")
	if err := os.WriteFile(configPath, []byte(`{"shell":"/definitely/missing","auth_token":"test"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := config.LoadOrCreate()
	if err != nil {
		t.Fatal(err)
	}
	old := &Session{ID: "old", Cwd: t.TempDir(), State: StateExited}
	m := &Manager{
		sessions: map[string]*Session{old.ID: old},
		order:    []string{old.ID},
		cfg:      store,
	}

	if _, err := m.Restart(old.ID); err == nil {
		t.Fatal("Restart returned nil error")
	}
	if got, ok := m.Get(old.ID); !ok || got != old {
		t.Fatal("old session was removed after replacement failed")
	}
	old.mu.Lock()
	closed := old.closed
	old.mu.Unlock()
	if closed {
		t.Fatal("old session was closed after replacement failed")
	}
}

func TestHandleExitRemovesSessionOnCleanExit(t *testing.T) {
	store := newManagerConfig(t, `{"close_tab_on_clean_exit":true,"shell":"/bin/zsh","auth_token":"test"}`)
	code := 0
	s := &Session{ID: "s1", State: StateExited, ExitCode: &code}
	m := &Manager{
		sessions: map[string]*Session{s.ID: s},
		order:    []string{s.ID},
		cfg:      store,
	}

	m.handleExit(s)

	if _, ok := m.Get(s.ID); ok {
		t.Fatal("clean exit should remove the session")
	}
	if len(m.List()) != 0 {
		t.Fatalf("session list = %d, want 0", len(m.List()))
	}
}

func TestHandleExitKeepsSessionOnNonZeroExit(t *testing.T) {
	store := newManagerConfig(t, `{"close_tab_on_clean_exit":true,"shell":"/bin/zsh","auth_token":"test"}`)
	code := 1
	s := &Session{ID: "s1", State: StateExited, ExitCode: &code}
	m := &Manager{
		sessions: map[string]*Session{s.ID: s},
		order:    []string{s.ID},
		cfg:      store,
	}

	m.handleExit(s)

	if _, ok := m.Get(s.ID); !ok {
		t.Fatal("non-zero exit should keep the session")
	}
}

func newManagerConfig(t *testing.T, raw string) *config.Store {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := filepath.Join(home, "Library", "Application Support", "WebTabinal")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "config.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := config.LoadOrCreate()
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func TestShouldCloseTab(t *testing.T) {
	code := func(v int) *int { return &v }
	for _, tc := range []struct {
		name             string
		info             Info
		closeOnCleanExit bool
		want             bool
	}{
		{
			name:             "signal with non-zero status closes",
			info:             Info{Integrated: true, PromptSeen: true, ShellExited: true, ExitCode: code(1)},
			closeOnCleanExit: true,
			want:             true,
		},
		{
			name:             "no signal with non-zero status keeps",
			info:             Info{Integrated: true, PromptSeen: true, ExitCode: code(1)},
			closeOnCleanExit: true,
			want:             false,
		},
		{
			name:             "no signal with zero status closes",
			info:             Info{Integrated: true, PromptSeen: true, ExitCode: code(0)},
			closeOnCleanExit: true,
			want:             true,
		},
		{
			name:             "disabled keeps despite signal",
			info:             Info{Integrated: true, PromptSeen: true, ShellExited: true, ExitCode: code(0)},
			closeOnCleanExit: false,
			want:             false,
		},
		{
			name:             "integrated without a prompt keeps despite zero status",
			info:             Info{Integrated: true, ExitCode: code(0)},
			closeOnCleanExit: true,
			want:             false,
		},
		{
			name:             "integrated without a prompt keeps despite signal",
			info:             Info{Integrated: true, ShellExited: true, ExitCode: code(0)},
			closeOnCleanExit: true,
			want:             false,
		},
		{
			name:             "unintegrated closes on zero status",
			info:             Info{ExitCode: code(0)},
			closeOnCleanExit: true,
			want:             true,
		},
		{
			name:             "unintegrated keeps on non-zero status",
			info:             Info{ExitCode: code(1)},
			closeOnCleanExit: true,
			want:             false,
		},
		{
			name:             "missing status without a signal keeps",
			info:             Info{Integrated: true, PromptSeen: true},
			closeOnCleanExit: true,
			want:             false,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldCloseTab(tc.info, tc.closeOnCleanExit); got != tc.want {
				t.Fatalf("shouldCloseTab = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestHandleExitRemovesSessionOnSignalledNonZeroExit(t *testing.T) {
	store := newManagerConfig(t, `{"close_tab_on_clean_exit":true,"shell":"/bin/zsh","auth_token":"test"}`)
	code := 1
	s := &Session{
		ID: "s1", State: StateExited, ExitCode: &code,
		Integrated: true, PromptSeen: true, ShellExited: true,
	}
	m := &Manager{
		sessions: map[string]*Session{s.ID: s},
		order:    []string{s.ID},
		cfg:      store,
	}

	m.handleExit(s)

	if _, ok := m.Get(s.ID); ok {
		t.Fatal("a signalled exit should remove the session even with status 1")
	}
}

func TestHandleExitKeepsSessionThatNeverReachedAPrompt(t *testing.T) {
	store := newManagerConfig(t, `{"close_tab_on_clean_exit":true,"shell":"/bin/zsh","auth_token":"test"}`)
	code := 0
	s := &Session{ID: "s1", State: StateExited, ExitCode: &code, Integrated: true}
	m := &Manager{
		sessions: map[string]*Session{s.ID: s},
		order:    []string{s.ID},
		cfg:      store,
	}

	m.handleExit(s)

	if _, ok := m.Get(s.ID); !ok {
		t.Fatal("a session that never prompted should keep its tab")
	}
}
