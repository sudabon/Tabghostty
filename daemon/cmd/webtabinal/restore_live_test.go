package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/restore"
	"github.com/sudabon/webtabinal/internal/session"
)

// liveRestoreEnv builds a real session.Manager against an isolated HOME so the
// restore path can be exercised with real PTYs and real shells.
func liveRestoreEnv(t *testing.T, restoreJSON string) (*session.Manager, string) {
	t.Helper()
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash is not available: %v", err)
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	support := filepath.Join(home, "Library", "Application Support", "WebTabinal")
	if err := os.MkdirAll(support, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `{"shell":"/bin/bash","auth_token":"test","restore":` + restoreJSON + `}`
	if err := os.WriteFile(filepath.Join(support, "config.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := config.LoadOrCreate()
	if err != nil {
		t.Fatal(err)
	}
	mgr := session.NewManager(store, nil)
	t.Cleanup(mgr.Close)
	return mgr, filepath.Join(support, "restore.json")
}

// waitForOutput polls a session's ring buffer until want shows up.
func waitForOutput(t *testing.T, mgr *session.Manager, id, want string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		s, ok := mgr.Get(id)
		if ok && strings.Contains(string(s.Ring.Bytes()), want) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	s, _ := mgr.Get(id)
	var got string
	if s != nil {
		got = string(s.Ring.Bytes())
	}
	t.Fatalf("session %s never produced %q\noutput:\n%s", id, want, got)
}

// The end-to-end restore path against real shells: tabs come back at their
// recorded directories with their memos, and the resume command actually runs.
// Harmless echo commands stand in for the agent CLIs.
func TestLiveRestoreRecreatesTabsAndRunsTheCommand(t *testing.T) {
	mgr, snapshotPath := liveRestoreEnv(t, `{"enabled":true,"max_sessions":8,"max_age_hours":72,
		"commands":{"claude":"echo WT_RESUMED_CLAUDE","codex":"echo WT_RESUMED_CODEX"}}`)

	root := t.TempDir()
	projA, projB := filepath.Join(root, "alpha"), filepath.Join(root, "beta")
	for _, p := range []string{projA, projB} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	snap := restore.Snapshot{UpdatedAt: time.Now(), Sessions: []restore.Entry{
		{Order: 0, Cwd: projA, Memo: "alpha memo", Agent: "claude", SeenAt: time.Now()},
		{Order: 1, Cwd: projB, Memo: "beta memo", Agent: "codex", SeenAt: time.Now()},
	}}
	if err := restore.Save(snapshotPath, snap); err != nil {
		t.Fatal(err)
	}

	cfg := config.RestoreConfig{
		Enabled:     true,
		MaxSessions: 8,
		MaxAgeHours: 72,
		Commands:    map[string]string{"claude": "echo WT_RESUMED_CLAUDE", "codex": "echo WT_RESUMED_CODEX"},
	}
	if got := runRestore(mgr, cfg, snapshotPath, nil); got != 2 {
		t.Fatalf("restored = %d, want 2", got)
	}

	list := mgr.List()
	if len(list) != 2 {
		t.Fatalf("sessions = %d, want 2", len(list))
	}
	if list[0].Cwd != projA || list[0].Memo != "alpha memo" {
		t.Fatalf("session 0 = %+v, want cwd %s and its memo", list[0], projA)
	}
	if list[1].Cwd != projB || list[1].Memo != "beta memo" {
		t.Fatalf("session 1 = %+v, want cwd %s and its memo", list[1], projB)
	}

	waitForOutput(t, mgr, list[0].ID, "WT_RESUMED_CLAUDE")
	waitForOutput(t, mgr, list[1].ID, "WT_RESUMED_CODEX")
}

func TestLiveRestoreDisabledCreatesNoSession(t *testing.T) {
	mgr, snapshotPath := liveRestoreEnv(t, `{"enabled":false,"max_sessions":8,"max_age_hours":72}`)

	proj := t.TempDir()
	snap := restore.Snapshot{UpdatedAt: time.Now(), Sessions: []restore.Entry{
		{Order: 0, Cwd: proj, Agent: "claude", SeenAt: time.Now()},
	}}
	if err := restore.Save(snapshotPath, snap); err != nil {
		t.Fatal(err)
	}

	cfg := config.RestoreConfig{Enabled: false, MaxSessions: 8, MaxAgeHours: 72}
	if got := runRestore(mgr, cfg, snapshotPath, nil); got != 0 {
		t.Fatalf("restored = %d, want 0", got)
	}
	if list := mgr.List(); len(list) != 0 {
		t.Fatalf("sessions = %+v, want none", list)
	}
	if _, err := os.Stat(snapshotPath); err != nil {
		t.Fatalf("snapshot was removed: %v", err)
	}
}

// The second tab on the same conversation gets the command typed but not run,
// so the shell must stay at its prompt with the text pending.
func TestLiveRestoreStagesTheSecondTabWithoutRunningIt(t *testing.T) {
	mgr, snapshotPath := liveRestoreEnv(t, `{"enabled":true,"max_sessions":8,"max_age_hours":72,
		"commands":{"claude":"echo WT_STAGED"}}`)

	proj := t.TempDir()
	snap := restore.Snapshot{UpdatedAt: time.Now(), Sessions: []restore.Entry{
		{Order: 0, Cwd: proj, Agent: "claude", SeenAt: time.Now()},
		{Order: 1, Cwd: proj, Agent: "claude", SeenAt: time.Now()},
	}}
	if err := restore.Save(snapshotPath, snap); err != nil {
		t.Fatal(err)
	}

	cfg := config.RestoreConfig{
		Enabled: true, MaxSessions: 8, MaxAgeHours: 72,
		Commands: map[string]string{"claude": "echo WT_STAGED"},
	}
	if got := runRestore(mgr, cfg, snapshotPath, nil); got != 2 {
		t.Fatalf("restored = %d, want both tabs", got)
	}

	list := mgr.List()
	// The first tab runs it, so its output carries the echoed value on a line of
	// its own; the second only ever echoes the typed characters back.
	waitForOutput(t, mgr, list[0].ID, "WT_STAGED")
	waitForOutput(t, mgr, list[1].ID, "echo WT_STAGED")

	second, ok := mgr.Get(list[1].ID)
	if !ok {
		t.Fatal("second session went away")
	}
	// Give the staged tab the same grace the first needed, then confirm it never
	// executed: a run would leave the output on its own line after the echo.
	time.Sleep(500 * time.Millisecond)
	out := string(second.Ring.Bytes())
	if strings.Count(out, "WT_STAGED") != 1 {
		t.Fatalf("staged tab shows %d occurrences of the command, want only the typed one\noutput:\n%s",
			strings.Count(out, "WT_STAGED"), out)
	}
}
