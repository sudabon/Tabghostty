// Package restore persists the coding-agent sessions a user had open and
// works out what to bring back on the next daemon start. It deliberately does
// not import internal/session: the policy here is pure data in, plan out, and
// the caller owns creating sessions.
package restore

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Version is the snapshot schema version. A snapshot written by a different
// version is treated as absent rather than as an error.
const Version = 1

// Entry describes one recorded agent session.
type Entry struct {
	Order  int       `json:"order"`
	Cwd    string    `json:"cwd"`
	Memo   string    `json:"memo"`
	Agent  string    `json:"agent"`
	SeenAt time.Time `json:"seen_at"`
}

// Snapshot is the on-disk form of the recorded session set.
type Snapshot struct {
	Version   int       `json:"version"`
	UpdatedAt time.Time `json:"updated_at"`
	Sessions  []Entry   `json:"sessions"`
}

// Save replaces the snapshot at path atomically. It writes a temporary file in
// the same directory and renames it over the target, so a concurrent reader
// sees either the whole previous snapshot or the whole new one.
func Save(path string, snap Snapshot) error {
	snap.Version = Version
	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// Same directory as the target, so the rename stays within one filesystem.
	tmp, err := os.CreateTemp(dir, ".restore-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		// A no-op once the rename succeeded; cleans up on every failure path.
		_ = os.Remove(tmpName)
	}()
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// Load reads the snapshot at path. A missing file, unreadable file, unparsable
// JSON, or unknown schema version is not an error the daemon should fail on:
// Load returns an empty snapshot plus a reason the caller can log, so startup
// continues with no restored sessions.
func Load(path string) (Snapshot, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return Snapshot{Version: Version}, fmt.Errorf("no restore snapshot at %s", path)
	}
	if err != nil {
		return Snapshot{Version: Version}, fmt.Errorf("read restore snapshot: %w", err)
	}
	var snap Snapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return Snapshot{Version: Version}, fmt.Errorf("parse restore snapshot %s: %w", path, err)
	}
	if snap.Version != Version {
		return Snapshot{Version: Version}, fmt.Errorf("restore snapshot %s has version %d, want %d", path, snap.Version, Version)
	}
	return snap, nil
}
