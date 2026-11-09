package restore

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
)

var planNow = time.Date(2026, 8, 19, 12, 0, 0, 0, time.UTC)

func restoreCfg() config.RestoreConfig {
	return config.RestoreConfig{Enabled: true, Commands: map[string]string{}, MaxSessions: 8, MaxAgeHours: 72}
}

// allDirsExist stands in for the filesystem so plan tests stay hermetic.
func allDirsExist(string) bool { return true }

func planOpts() PlanOpts {
	return PlanOpts{Now: planNow, DirExists: allDirsExist}
}

func entry(order int, cwd, agent string) Entry {
	return Entry{Order: order, Cwd: cwd, Agent: agent, SeenAt: planNow.Add(-time.Hour)}
}

func TestBuildPlanKeepsRecordedOrder(t *testing.T) {
	snap := Snapshot{Sessions: []Entry{
		entry(2, "/c", "codex"),
		entry(0, "/a", "claude"),
		entry(1, "/b", "cursor-agent"),
	}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	if len(plan.Items) != 3 {
		t.Fatalf("items = %+v, want 3", plan.Items)
	}
	wantCwd := []string{"/a", "/b", "/c"}
	for i, want := range wantCwd {
		if plan.Items[i].Cwd != want {
			t.Fatalf("item %d cwd = %q, want %q", i, plan.Items[i].Cwd, want)
		}
	}
}

func TestBuildPlanCarriesMemoAndCommand(t *testing.T) {
	e := entry(0, "/proj", "codex")
	e.Memo = "リファクタ"
	snap := Snapshot{Sessions: []Entry{e}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	if len(plan.Items) != 1 {
		t.Fatalf("items = %+v, want 1", plan.Items)
	}
	got := plan.Items[0]
	if got.Memo != "リファクタ" {
		t.Fatalf("memo = %q, want it carried through", got.Memo)
	}
	if got.Command != "codex resume --last" {
		t.Fatalf("command = %q, want the codex built-in", got.Command)
	}
	if !got.Autorun {
		t.Fatal("autorun = false, want the only tab for this directory to run")
	}
	if got.Input() != "codex resume --last\n" {
		t.Fatalf("input = %q, want a trailing newline", got.Input())
	}
}

func TestBuildPlanDisabledRestoreYieldsNothing(t *testing.T) {
	cfg := restoreCfg()
	cfg.Enabled = false
	snap := Snapshot{Sessions: []Entry{entry(0, "/a", "claude")}}

	plan := BuildPlan(snap, cfg, planOpts())

	if len(plan.Items) != 0 || len(plan.Skips) != 0 {
		t.Fatalf("plan = %+v, want nothing when restore is disabled", plan)
	}
}

func TestBuildPlanOverrideAndDisablingCommands(t *testing.T) {
	cfg := restoreCfg()
	cfg.Commands = map[string]string{"claude": "claude --resume", "cursor-agent": ""}
	snap := Snapshot{Sessions: []Entry{
		entry(0, "/a", "claude"),
		entry(1, "/b", "cursor-agent"),
	}}

	plan := BuildPlan(snap, cfg, planOpts())

	if len(plan.Items) != 1 || plan.Items[0].Command != "claude --resume" {
		t.Fatalf("items = %+v, want only the overridden claude entry", plan.Items)
	}
	if len(plan.Skips) != 1 || !strings.Contains(plan.Skips[0].Reason, "disabled") {
		t.Fatalf("skips = %+v, want the disabled cursor-agent skipped", plan.Skips)
	}
}

func TestBuildPlanSkipsUnmappedAgent(t *testing.T) {
	snap := Snapshot{Sessions: []Entry{entry(0, "/a", "generic")}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	if len(plan.Items) != 0 {
		t.Fatalf("items = %+v, want none", plan.Items)
	}
	if len(plan.Skips) != 1 || !strings.Contains(plan.Skips[0].Reason, "no resume command") {
		t.Fatalf("skips = %+v, want a reason naming the missing command", plan.Skips)
	}
}

func TestBuildPlanSkipsMissingDirectoryAgainstTheRealFilesystem(t *testing.T) {
	live := t.TempDir()
	gone := filepath.Join(live, "deleted")
	notADir := filepath.Join(live, "file.txt")
	if err := os.WriteFile(notADir, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	snap := Snapshot{Sessions: []Entry{
		entry(0, live, "claude"),
		entry(1, gone, "codex"),
		entry(2, notADir, "cursor-agent"),
	}}

	// No DirExists override: this exercises the production stat.
	plan := BuildPlan(snap, restoreCfg(), PlanOpts{Now: planNow})

	if len(plan.Items) != 1 || plan.Items[0].Cwd != live {
		t.Fatalf("items = %+v, want only the surviving directory", plan.Items)
	}
	if len(plan.Skips) != 2 {
		t.Fatalf("skips = %+v, want the deleted path and the plain file skipped", plan.Skips)
	}
	for _, skip := range plan.Skips {
		if !strings.Contains(skip.Reason, "no longer exists") {
			t.Fatalf("reason = %q, want it to name the missing directory", skip.Reason)
		}
	}
}

func TestBuildPlanSkipsStaleEntries(t *testing.T) {
	fresh := Entry{Order: 0, Cwd: "/fresh", Agent: "claude", SeenAt: planNow.Add(-71 * time.Hour)}
	stale := Entry{Order: 1, Cwd: "/stale", Agent: "codex", SeenAt: planNow.Add(-100 * time.Hour)}
	snap := Snapshot{Sessions: []Entry{fresh, stale}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	if len(plan.Items) != 1 || plan.Items[0].Cwd != "/fresh" {
		t.Fatalf("items = %+v, want only the fresh entry", plan.Items)
	}
	if len(plan.Skips) != 1 || !strings.Contains(plan.Skips[0].Reason, "72h limit") {
		t.Fatalf("skips = %+v, want the stale entry skipped with the limit named", plan.Skips)
	}
}

func TestBuildPlanZeroMaxAgeDisablesTheAgeCheck(t *testing.T) {
	cfg := restoreCfg()
	cfg.MaxAgeHours = 0
	ancient := Entry{Order: 0, Cwd: "/old", Agent: "claude", SeenAt: planNow.Add(-10000 * time.Hour)}

	plan := BuildPlan(Snapshot{Sessions: []Entry{ancient}}, cfg, planOpts())

	if len(plan.Items) != 1 {
		t.Fatalf("items = %+v, want the age check disabled by max_age_hours=0", plan.Items)
	}
}

func TestBuildPlanCapsSessionCount(t *testing.T) {
	cfg := restoreCfg()
	cfg.MaxSessions = 8
	var sessions []Entry
	for i := range 12 {
		sessions = append(sessions, entry(i, fmt.Sprintf("/proj%02d", i), "claude"))
	}

	plan := BuildPlan(Snapshot{Sessions: sessions}, cfg, planOpts())

	if len(plan.Items) != 8 {
		t.Fatalf("items = %d, want the cap of 8", len(plan.Items))
	}
	if plan.Items[0].Cwd != "/proj00" || plan.Items[7].Cwd != "/proj07" {
		t.Fatalf("items = %+v, want the first 8 in recorded order", plan.Items)
	}
	if len(plan.Skips) != 4 {
		t.Fatalf("skips = %d, want the remaining 4 logged", len(plan.Skips))
	}
	for _, skip := range plan.Skips {
		if !strings.Contains(skip.Reason, "restore limit of 8") {
			t.Fatalf("reason = %q, want it to name the limit", skip.Reason)
		}
	}
}

// An ineligible entry must not consume the session budget: the cap counts what
// is actually restored.
func TestBuildPlanCapCountsOnlyRestoredEntries(t *testing.T) {
	cfg := restoreCfg()
	cfg.MaxSessions = 2
	snap := Snapshot{Sessions: []Entry{
		entry(0, "/a", "generic"), // skipped, must not use a slot
		entry(1, "/b", "claude"),
		entry(2, "/c", "codex"),
		entry(3, "/d", "claude"),
	}}

	plan := BuildPlan(snap, cfg, planOpts())

	if len(plan.Items) != 2 {
		t.Fatalf("items = %+v, want 2", plan.Items)
	}
	if plan.Items[0].Cwd != "/b" || plan.Items[1].Cwd != "/c" {
		t.Fatalf("items = %+v, want /b and /c", plan.Items)
	}
}

func TestBuildPlanStagesDuplicateAgentAndDirectory(t *testing.T) {
	snap := Snapshot{Sessions: []Entry{
		entry(0, "/Users/me/proj", "claude"),
		entry(1, "/Users/me/proj", "claude"),
		entry(2, "/Users/me/proj", "claude"),
	}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	if len(plan.Items) != 3 {
		t.Fatalf("items = %+v, want all three tabs restored", plan.Items)
	}
	if !plan.Items[0].Autorun {
		t.Fatal("first tab should execute the resume command")
	}
	if plan.Items[0].Input() != "claude --continue\n" {
		t.Fatalf("first input = %q, want a trailing newline", plan.Items[0].Input())
	}
	for _, item := range plan.Items[1:] {
		if item.Autorun {
			t.Fatalf("item %+v should be staged, not executed", item)
		}
		if item.Input() != "claude --continue" {
			t.Fatalf("staged input = %q, want no trailing newline", item.Input())
		}
	}
}

func TestBuildPlanDuplicateDirectoryWithDifferentAgentsBothRun(t *testing.T) {
	snap := Snapshot{Sessions: []Entry{
		entry(0, "/Users/me/proj", "claude"),
		entry(1, "/Users/me/proj", "codex"),
	}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	if len(plan.Items) != 2 {
		t.Fatalf("items = %+v, want 2", plan.Items)
	}
	for _, item := range plan.Items {
		if !item.Autorun {
			t.Fatalf("item %+v should run: a different agent is a different conversation", item)
		}
	}
}

func TestBuildPlanSameAgentDifferentDirectoriesBothRun(t *testing.T) {
	snap := Snapshot{Sessions: []Entry{
		entry(0, "/a", "claude"),
		entry(1, "/b", "claude"),
	}}

	plan := BuildPlan(snap, restoreCfg(), planOpts())

	for _, item := range plan.Items {
		if !item.Autorun {
			t.Fatalf("item %+v should run: a different directory is a different conversation", item)
		}
	}
}

func TestBuildPlanEmptySnapshotYieldsNothing(t *testing.T) {
	plan := BuildPlan(Snapshot{}, restoreCfg(), planOpts())

	if len(plan.Items) != 0 || len(plan.Skips) != 0 {
		t.Fatalf("plan = %+v, want nothing", plan)
	}
}
