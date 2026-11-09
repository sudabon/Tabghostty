package main

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/restore"
	"github.com/sudabon/webtabinal/internal/session"
)

// fakeManager stands in for session.Manager. CreateRestored records the request
// and hands back a nil session, which is all SendWhenReady needs here.
type fakeManager struct {
	live    []session.Info
	created []created
	sent    []string
	failAt  map[string]error
}

type created struct {
	cwd  string
	memo string
}

func (f *fakeManager) List() []session.Info { return f.live }

func (f *fakeManager) CreateRestored(cwd, memo string) (*session.Session, error) {
	if err := f.failAt[cwd]; err != nil {
		return nil, err
	}
	f.created = append(f.created, created{cwd: cwd, memo: memo})
	// Mirror the real manager: a created session joins the live listing.
	f.live = append(f.live, session.Info{
		Order: len(f.live),
		Cwd:   cwd,
		Memo:  memo,
		State: session.StateStarting,
	})
	return nil, nil
}

func (f *fakeManager) SendWhenReady(_ *session.Session, input string) {
	f.sent = append(f.sent, input)
}

// setAgent marks a live session as running an agent, as the detector would.
func (f *fakeManager) setAgent(cwd, agent string) {
	for i := range f.live {
		if f.live[i].Cwd == cwd {
			f.live[i].Agent = agent
		}
	}
}

func restoreConfig() config.RestoreConfig {
	return config.RestoreConfig{Enabled: true, Commands: map[string]string{}, MaxSessions: 8, MaxAgeHours: 72}
}

func writeSnapshot(t *testing.T, dir string, entries ...restore.Entry) string {
	t.Helper()
	path := filepath.Join(dir, "restore.json")
	if err := restore.Save(path, restore.Snapshot{UpdatedAt: time.Now(), Sessions: entries}); err != nil {
		t.Fatal(err)
	}
	return path
}

func testLogger() (*log.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	return log.New(&buf, "", 0), &buf
}

func TestRunRestoreRecreatesTabsInOrder(t *testing.T) {
	dir := t.TempDir()
	projA, projB := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	for _, p := range []string{projA, projB} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	path := writeSnapshot(t, dir,
		restore.Entry{Order: 1, Cwd: projB, Memo: "second", Agent: "codex", SeenAt: time.Now()},
		restore.Entry{Order: 0, Cwd: projA, Memo: "first", Agent: "claude", SeenAt: time.Now()},
	)
	mgr := &fakeManager{}
	logger, _ := testLogger()

	got := runRestore(mgr, restoreConfig(), path, logger)

	if got != 2 {
		t.Fatalf("restored = %d, want 2", got)
	}
	want := []created{{cwd: projA, memo: "first"}, {cwd: projB, memo: "second"}}
	if len(mgr.created) != 2 || mgr.created[0] != want[0] || mgr.created[1] != want[1] {
		t.Fatalf("created = %+v, want %+v", mgr.created, want)
	}
	wantSent := []string{"claude --continue\n", "codex resume --last\n"}
	if strings.Join(mgr.sent, "|") != strings.Join(wantSent, "|") {
		t.Fatalf("sent = %q, want %q", mgr.sent, wantSent)
	}
}

func TestRunRestoreDisabledCreatesNothingAndKeepsTheSnapshot(t *testing.T) {
	dir := t.TempDir()
	proj := filepath.Join(dir, "proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	path := writeSnapshot(t, dir, restore.Entry{Cwd: proj, Agent: "claude", SeenAt: time.Now()})
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	cfg := restoreConfig()
	cfg.Enabled = false
	mgr := &fakeManager{}
	logger, logs := testLogger()

	got := runRestore(mgr, cfg, path, logger)

	if got != 0 || len(mgr.created) != 0 {
		t.Fatalf("created %d session(s), want none when restore is disabled", len(mgr.created))
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("snapshot was removed: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("snapshot content changed while restore was disabled")
	}
	if !strings.Contains(logs.String(), "disabled") {
		t.Fatalf("log = %q, want it to note restore is disabled", logs.String())
	}
}

func TestRunRestoreSkippedWhenSessionsAlreadyExist(t *testing.T) {
	dir := t.TempDir()
	proj := filepath.Join(dir, "proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	path := writeSnapshot(t, dir, restore.Entry{Cwd: proj, Agent: "claude", SeenAt: time.Now()})
	mgr := &fakeManager{live: []session.Info{{Cwd: "/somewhere"}}}
	logger, logs := testLogger()

	if got := runRestore(mgr, restoreConfig(), path, logger); got != 0 {
		t.Fatalf("restored = %d, want 0 when sessions already exist", got)
	}
	if len(mgr.created) != 0 {
		t.Fatalf("created = %+v, want none", mgr.created)
	}
	if !strings.Contains(logs.String(), "already exist") {
		t.Fatalf("log = %q, want it to say why restore was skipped", logs.String())
	}
}

func TestRunRestoreContinuesWithACorruptSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "restore.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	mgr := &fakeManager{}
	logger, logs := testLogger()

	got := runRestore(mgr, restoreConfig(), path, logger)

	if got != 0 || len(mgr.created) != 0 {
		t.Fatalf("created = %+v, want none from a corrupt snapshot", mgr.created)
	}
	if !strings.Contains(logs.String(), "parse restore snapshot") {
		t.Fatalf("log = %q, want the parse failure recorded", logs.String())
	}
}

func TestRunRestoreContinuesWithNoSnapshotFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent.json")
	mgr := &fakeManager{}
	logger, logs := testLogger()

	if got := runRestore(mgr, restoreConfig(), path, logger); got != 0 {
		t.Fatalf("restored = %d, want 0", got)
	}
	if !strings.Contains(logs.String(), "no restore snapshot") {
		t.Fatalf("log = %q, want the missing snapshot noted", logs.String())
	}
}

func TestRunRestoreLogsSkipReasons(t *testing.T) {
	dir := t.TempDir()
	proj := filepath.Join(dir, "proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	path := writeSnapshot(t, dir,
		restore.Entry{Order: 0, Cwd: filepath.Join(dir, "deleted"), Agent: "claude", SeenAt: time.Now()},
		restore.Entry{Order: 1, Cwd: proj, Agent: "generic", SeenAt: time.Now()},
		restore.Entry{Order: 2, Cwd: proj, Agent: "codex", SeenAt: time.Now().Add(-200 * time.Hour)},
	)
	mgr := &fakeManager{}
	logger, logs := testLogger()

	if got := runRestore(mgr, restoreConfig(), path, logger); got != 0 {
		t.Fatalf("restored = %d, want 0", got)
	}
	out := logs.String()
	for _, want := range []string{"no longer exists", "no resume command", "72h limit"} {
		if !strings.Contains(out, want) {
			t.Fatalf("log = %q, want it to contain %q", out, want)
		}
	}
}

func TestRunRestoreLogsRejectedCommand(t *testing.T) {
	dir := t.TempDir()
	proj := filepath.Join(dir, "proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	path := writeSnapshot(t, dir, restore.Entry{Cwd: proj, Agent: "claude", SeenAt: time.Now()})
	cfg := restoreConfig()
	cfg.Commands = map[string]string{"claude": "claude --continue\nrm -rf /"}
	mgr := &fakeManager{}
	logger, logs := testLogger()

	if got := runRestore(mgr, cfg, path, logger); got != 0 {
		t.Fatalf("restored = %d, want the rejected command to create nothing", got)
	}
	if !strings.Contains(logs.String(), "line break") {
		t.Fatalf("log = %q, want the rejection recorded", logs.String())
	}
}

func TestRunRestoreStagesSecondTabInTheSameDirectory(t *testing.T) {
	dir := t.TempDir()
	proj := filepath.Join(dir, "proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	path := writeSnapshot(t, dir,
		restore.Entry{Order: 0, Cwd: proj, Agent: "claude", SeenAt: time.Now()},
		restore.Entry{Order: 1, Cwd: proj, Agent: "claude", SeenAt: time.Now()},
	)
	mgr := &fakeManager{}
	logger, _ := testLogger()

	if got := runRestore(mgr, restoreConfig(), path, logger); got != 2 {
		t.Fatalf("restored = %d, want both tabs", got)
	}
	if mgr.sent[0] != "claude --continue\n" {
		t.Fatalf("first input = %q, want it executed", mgr.sent[0])
	}
	if mgr.sent[1] != "claude --continue" {
		t.Fatalf("second input = %q, want it staged without a newline", mgr.sent[1])
	}
}

func TestRunRestoreKeepsGoingWhenOneSessionFailsToStart(t *testing.T) {
	dir := t.TempDir()
	bad, good := filepath.Join(dir, "bad"), filepath.Join(dir, "good")
	for _, p := range []string{bad, good} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	path := writeSnapshot(t, dir,
		restore.Entry{Order: 0, Cwd: bad, Agent: "claude", SeenAt: time.Now()},
		restore.Entry{Order: 1, Cwd: good, Agent: "codex", SeenAt: time.Now()},
	)
	mgr := &fakeManager{failAt: map[string]error{bad: fmt.Errorf("no pty available")}}
	logger, logs := testLogger()

	if got := runRestore(mgr, restoreConfig(), path, logger); got != 1 {
		t.Fatalf("restored = %d, want the second session still created", got)
	}
	if len(mgr.created) != 1 || mgr.created[0].cwd != good {
		t.Fatalf("created = %+v, want only the good directory", mgr.created)
	}
	if !strings.Contains(logs.String(), "no pty available") {
		t.Fatalf("log = %q, want the create failure recorded", logs.String())
	}
}

// A restore pass followed by a recorder write and a second start must land on
// the same tab count, not double it.
func TestRestoreThenRestartDoesNotMultiplyTabs(t *testing.T) {
	dir := t.TempDir()
	projA, projB := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	for _, p := range []string{projA, projB} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	path := writeSnapshot(t, dir,
		restore.Entry{Order: 0, Cwd: projA, Agent: "claude", SeenAt: time.Now()},
		restore.Entry{Order: 1, Cwd: projB, Agent: "codex", SeenAt: time.Now()},
	)
	cfg := restoreConfig()
	logger, _ := testLogger()

	first := &fakeManager{}
	if got := runRestore(first, cfg, path, logger); got != 2 {
		t.Fatalf("first start restored %d, want 2", got)
	}
	// Both resumed agents get detected, and the recorder persists the live set.
	first.setAgent(projA, "claude")
	first.setAgent(projB, "codex")
	recordOnce(t, path, first, cfg)

	second := &fakeManager{}
	if got := runRestore(second, cfg, path, logger); got != 2 {
		t.Fatalf("second start restored %d, want exactly 2", got)
	}
}

// An entry whose resume command left no agent running must drop out.
func TestFailedResumeDropsOutOfTheNextStart(t *testing.T) {
	dir := t.TempDir()
	projA, projB := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	for _, p := range []string{projA, projB} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	path := writeSnapshot(t, dir,
		restore.Entry{Order: 0, Cwd: projA, Agent: "claude", SeenAt: time.Now()},
		restore.Entry{Order: 1, Cwd: projB, Agent: "codex", SeenAt: time.Now()},
	)
	cfg := restoreConfig()
	logger, _ := testLogger()

	first := &fakeManager{}
	runRestore(first, cfg, path, logger)
	// Only projA's agent survived; projB fell back to a plain shell.
	first.setAgent(projA, "claude")
	recordOnce(t, path, first, cfg)

	second := &fakeManager{}
	if got := runRestore(second, cfg, path, logger); got != 1 {
		t.Fatalf("second start restored %d, want only the surviving agent", got)
	}
	if len(second.created) != 1 || second.created[0].cwd != projA {
		t.Fatalf("created = %+v, want only %s", second.created, projA)
	}
}

// recordOnce runs a single recorder cycle over the manager's live sessions,
// exactly as the daemon's recorder does on its interval.
func recordOnce(t *testing.T, path string, mgr restoreSessions, cfg config.RestoreConfig) {
	t.Helper()
	rec := restore.StartRecorder(restore.RecorderOpts{
		Path:      path,
		Observe:   func() []restore.Observed { return observedFrom(mgr.List()) },
		Overrides: func() map[string]string { return cfg.Commands },
		Ticks:     make(chan time.Time),
	})
	rec.Tick()
	rec.Stop()
}

func TestObservedFromCarriesTheRecorderFields(t *testing.T) {
	list := []session.Info{
		{Order: 0, Cwd: "/a", Memo: "memo", Agent: "claude", State: session.StateIdle},
		{Order: 1, Cwd: "/b", Agent: "", State: session.StateRunning},
	}

	got := observedFrom(list)

	want := []restore.Observed{
		{Order: 0, Cwd: "/a", Memo: "memo", Agent: "claude"},
		{Order: 1, Cwd: "/b"},
	}
	if len(got) != len(want) {
		t.Fatalf("observed = %+v, want %d", got, len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("observed %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}
