package restore

import (
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/sudabon/webtabinal/internal/config"
)

// PlanItem is one session the daemon should recreate.
type PlanItem struct {
	Order   int
	Cwd     string
	Memo    string
	Agent   string
	Command string
	// Autorun is false for the second and later items sharing an agent and CWD.
	// `claude --continue` and `codex resume --last` both pick the most recent
	// conversation for the directory, so running two of them would open the same
	// conversation twice; the later tabs get the command staged on their input
	// line instead and the user decides.
	Autorun bool
}

// Skip records an entry the daemon will not restore, with why.
type Skip struct {
	Entry  Entry
	Reason string
}

// Plan is the ordered result of evaluating a snapshot.
type Plan struct {
	Items []PlanItem
	Skips []Skip
}

// PlanOpts carries the inputs a plan needs beyond the snapshot and config.
type PlanOpts struct {
	// Now is the reference time for the age check. Zero means time.Now.
	Now time.Time
	// DirExists reports whether a recorded CWD is still a directory. Nil means
	// a real filesystem check.
	DirExists func(string) bool
}

// BuildPlan decides what to restore from a snapshot. Entries are taken in
// recorded order; every rejected entry lands in Skips with a reason so the
// caller can log it. Restore being disabled yields an empty plan, so a caller
// that forgets to check the flag still creates nothing.
func BuildPlan(snap Snapshot, cfg config.RestoreConfig, opts PlanOpts) Plan {
	if !cfg.Enabled {
		return Plan{}
	}
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	dirExists := opts.DirExists
	if dirExists == nil {
		dirExists = isDir
	}

	entries := append([]Entry(nil), snap.Sessions...)
	// Recorded order is what the user saw as tab order; sorting on it keeps the
	// plan stable even if the file was edited or written out of order.
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].Order < entries[j].Order })

	plan := Plan{}
	// autorunTaken tracks which agent+directory pairs already have a tab that
	// will execute the command.
	autorunTaken := make(map[string]bool, len(entries))
	for _, entry := range entries {
		resolution := ResolveCommand(entry.Agent, cfg.Commands)
		if !resolution.OK {
			plan.Skips = append(plan.Skips, Skip{Entry: entry, Reason: resolution.Reason})
			continue
		}
		if entry.Cwd == "" || !dirExists(entry.Cwd) {
			plan.Skips = append(plan.Skips, Skip{
				Entry:  entry,
				Reason: fmt.Sprintf("directory %q no longer exists", entry.Cwd),
			})
			continue
		}
		if cfg.MaxAgeHours > 0 {
			maxAge := time.Duration(cfg.MaxAgeHours) * time.Hour
			if age := now.Sub(entry.SeenAt); age > maxAge {
				plan.Skips = append(plan.Skips, Skip{
					Entry:  entry,
					Reason: fmt.Sprintf("last seen %s ago, older than the %dh limit", age.Round(time.Minute), cfg.MaxAgeHours),
				})
				continue
			}
		}
		if len(plan.Items) >= cfg.MaxSessions {
			plan.Skips = append(plan.Skips, Skip{
				Entry:  entry,
				Reason: fmt.Sprintf("restore limit of %d sessions reached", cfg.MaxSessions),
			})
			continue
		}

		key := entry.Agent + "\x00" + entry.Cwd
		autorun := !autorunTaken[key]
		autorunTaken[key] = true
		plan.Items = append(plan.Items, PlanItem{
			Order:   entry.Order,
			Cwd:     entry.Cwd,
			Memo:    entry.Memo,
			Agent:   entry.Agent,
			Command: resolution.Command,
			Autorun: autorun,
		})
	}
	return plan
}

// Input is what a restored session should receive: the command, plus a newline
// only when it is meant to run.
func (p PlanItem) Input() string {
	if p.Autorun {
		return p.Command + "\n"
	}
	return p.Command
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
