package main

import (
	"log"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/restore"
	"github.com/sudabon/webtabinal/internal/session"
)

// restoreSessions is the slice of session.Manager a restore pass needs. Keeping
// it narrow lets the startup path be tested without a PTY or an HTTP server.
type restoreSessions interface {
	List() []session.Info
	CreateRestored(cwd, memo string) (*session.Session, error)
	SendWhenReady(s *session.Session, input string)
}

// observedFrom maps a live session listing onto what the recorder persists.
// Manager.List already fills Agent in through its detector, so no extra
// plumbing is needed on the manager side.
func observedFrom(list []session.Info) []restore.Observed {
	out := make([]restore.Observed, 0, len(list))
	for _, info := range list {
		out = append(out, restore.Observed{
			Order: info.Order,
			Cwd:   info.Cwd,
			Memo:  info.Memo,
			Agent: info.Agent,
		})
	}
	return out
}

// runRestore recreates the agent tabs recorded in the snapshot at path and
// returns how many it created. It never fails startup: an unusable snapshot is
// logged and treated as empty. The snapshot is only read, never removed, so
// turning restore off does not throw the recorded set away.
func runRestore(mgr restoreSessions, cfg config.RestoreConfig, path string, logger *log.Logger) int {
	if !cfg.Enabled {
		logf(logger, "restore: disabled, leaving %s untouched", path)
		return 0
	}
	if existing := len(mgr.List()); existing > 0 {
		logf(logger, "restore: skipped, %d session(s) already exist", existing)
		return 0
	}

	snap, err := restore.Load(path)
	if err != nil {
		// Load returns an empty snapshot alongside the reason, so continuing
		// here simply restores nothing.
		logf(logger, "restore: %v", err)
	}

	plan := restore.BuildPlan(snap, cfg, restore.PlanOpts{})
	for _, skip := range plan.Skips {
		logf(logger, "restore: skipped %s (agent %s): %s", skip.Entry.Cwd, skip.Entry.Agent, skip.Reason)
	}

	created := 0
	for _, item := range plan.Items {
		s, err := mgr.CreateRestored(item.Cwd, item.Memo)
		if err != nil {
			logf(logger, "restore: create session at %s: %v", item.Cwd, err)
			continue
		}
		mgr.SendWhenReady(s, item.Input())
		created++
		if item.Autorun {
			logf(logger, "restore: %s at %s runs %q", item.Agent, item.Cwd, item.Command)
		} else {
			// Two tabs on the same conversation would resume it twice, so the
			// later ones are staged for the user to run.
			logf(logger, "restore: %s at %s staged %q without running it", item.Agent, item.Cwd, item.Command)
		}
	}
	if created > 0 || len(plan.Skips) > 0 {
		logf(logger, "restore: restored %d session(s), skipped %d", created, len(plan.Skips))
	}
	return created
}

func logf(logger *log.Logger, format string, args ...any) {
	if logger != nil {
		logger.Printf(format, args...)
	}
}
