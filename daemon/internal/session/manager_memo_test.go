package session

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/config"
)

func testManager(t *testing.T) *Manager {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := filepath.Join(home, "Library", "Application Support", "WebTabinal")
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(configDir, "config.json")
	if err := os.WriteFile(configPath, []byte(`{"shell":"/bin/sh","auth_token":"test"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := config.LoadOrCreate()
	if err != nil {
		t.Fatal(err)
	}
	return NewManager(store, log.New(io.Discard, "", 0))
}

func TestDuplicateDoesNotCopyMemo(t *testing.T) {
	m := testManager(t)
	defer m.Close()
	s, err := m.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetMemo("CI watch"); err != nil {
		t.Fatal(err)
	}
	dup, err := m.Duplicate(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got := dup.Info().Memo; got != "" {
		t.Fatalf("duplicate memo = %q, want empty", got)
	}
	if got := s.Info().Memo; got != "CI watch" {
		t.Fatalf("source memo = %q, want CI watch", got)
	}
}

func TestRestartCopiesMemo(t *testing.T) {
	m := testManager(t)
	defer m.Close()
	s, err := m.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetMemo("CI watch"); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.State = StateExited
	s.mu.Unlock()

	ns, err := m.Restart(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got := ns.Info().Memo; got != "CI watch" {
		t.Fatalf("restarted memo = %q, want CI watch", got)
	}
	if _, ok := m.Get(s.ID); ok {
		t.Fatal("old session should be removed after restart")
	}
}

func TestPatchSessionRejectsMemoWithoutApplyingMute(t *testing.T) {
	m := testManager(t)
	defer m.Close()
	s, err := m.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	m.SetHooks(func() { calls++ }, nil, nil, nil)

	tooLong := strings.Repeat("あ", MaxMemoRunes+1)
	muted := true
	if _, err := m.PatchSession(s.ID, &tooLong, &muted); err == nil {
		t.Fatal("expected over-limit memo to be rejected")
	}
	if s.Info().NotificationsMuted {
		t.Fatal("mute must not apply when memo is rejected")
	}
	if calls != 0 {
		t.Fatalf("onChange calls = %d, want 0", calls)
	}

	memo := " CI watch "
	if _, err := m.PatchSession(s.ID, &memo, &muted); err != nil {
		t.Fatal(err)
	}
	info := s.Info()
	if info.Memo != "CI watch" || !info.NotificationsMuted {
		t.Fatalf("info = memo %q muted %v, want CI watch / true", info.Memo, info.NotificationsMuted)
	}
	if calls != 1 {
		t.Fatalf("onChange calls = %d, want 1", calls)
	}
}

func TestPatchSessionMuteLeavesMemo(t *testing.T) {
	m := testManager(t)
	defer m.Close()
	s, err := m.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetMemo("CI watch"); err != nil {
		t.Fatal(err)
	}
	muted := true
	if _, err := m.PatchSession(s.ID, nil, &muted); err != nil {
		t.Fatal(err)
	}
	info := s.Info()
	if info.Memo != "CI watch" || !info.NotificationsMuted {
		t.Fatalf("info = memo %q muted %v, want CI watch / true", info.Memo, info.NotificationsMuted)
	}
}

func TestDuplicateDoesNotCopyNotificationMute(t *testing.T) {
	m := testManager(t)
	defer m.Close()
	s, err := m.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	muted := true
	if err := s.Patch(nil, &muted); err != nil {
		t.Fatal(err)
	}
	dup, err := m.Duplicate(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if dup.Info().NotificationsMuted {
		t.Fatal("duplicate should not be muted")
	}
}

func TestRestartCopiesNotificationMute(t *testing.T) {
	m := testManager(t)
	defer m.Close()
	s, err := m.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	muted := true
	if err := s.Patch(nil, &muted); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.State = StateExited
	s.mu.Unlock()

	ns, err := m.Restart(s.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !ns.Info().NotificationsMuted {
		t.Fatal("restarted session should stay muted")
	}
}
