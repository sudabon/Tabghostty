package restore

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "restore.json")
	seen := time.Date(2026, 8, 19, 10, 30, 0, 0, time.UTC)
	want := Snapshot{
		UpdatedAt: seen,
		Sessions: []Entry{
			{Order: 0, Cwd: "/Users/me/proj", Memo: "レビュー", Agent: "claude", SeenAt: seen},
			{Order: 1, Cwd: "/Users/me/other", Agent: "codex", SeenAt: seen},
		},
	}

	if err := Save(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if got.Version != Version {
		t.Fatalf("version = %d, want %d", got.Version, Version)
	}
	if len(got.Sessions) != len(want.Sessions) {
		t.Fatalf("sessions = %+v, want %d entries", got.Sessions, len(want.Sessions))
	}
	for i, entry := range want.Sessions {
		if got.Sessions[i].Cwd != entry.Cwd || got.Sessions[i].Memo != entry.Memo ||
			got.Sessions[i].Agent != entry.Agent || got.Sessions[i].Order != entry.Order {
			t.Fatalf("entry %d = %+v, want %+v", i, got.Sessions[i], entry)
		}
		if !got.Sessions[i].SeenAt.Equal(entry.SeenAt) {
			t.Fatalf("entry %d seen_at = %v, want %v", i, got.Sessions[i].SeenAt, entry.SeenAt)
		}
	}
}

func TestSaveStampsVersion(t *testing.T) {
	path := filepath.Join(t.TempDir(), "restore.json")

	// Version 0 in, current version on disk: callers never set it themselves.
	if err := Save(path, Snapshot{}); err != nil {
		t.Fatal(err)
	}

	var raw map[string]any
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if raw["version"] != float64(Version) {
		t.Fatalf("version on disk = %v, want %d", raw["version"], Version)
	}
}

func TestSaveIsOwnerOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "restore.json")
	if err := Save(path, Snapshot{}); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("permissions = %04o, want 0600", perm)
	}
}

func TestSaveCreatesMissingParentDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "dir", "restore.json")

	if err := Save(path, Snapshot{}); err != nil {
		t.Fatalf("Save into a missing directory: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
}

// A reader must never see a half-written file, which is why Save renames into
// place instead of truncating the target.
func TestSaveNeverExposesAPartialSnapshot(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "restore.json")
	big := strings.Repeat("x", 4096)
	first := Snapshot{Sessions: []Entry{{Cwd: "/first", Agent: "claude", Memo: big}}}
	if err := Save(path, first); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			// Every observation must parse and name exactly one of the two
			// complete snapshots.
			snap, err := Load(path)
			if err != nil {
				t.Errorf("reader saw an unloadable snapshot: %v", err)
				return
			}
			if len(snap.Sessions) != 1 {
				t.Errorf("reader saw %d entries, want 1", len(snap.Sessions))
				return
			}
			if cwd := snap.Sessions[0].Cwd; cwd != "/first" && cwd != "/second" {
				t.Errorf("reader saw cwd %q, want a complete snapshot", cwd)
				return
			}
		}
	}()

	for range 50 {
		next := Snapshot{Sessions: []Entry{{Cwd: "/second", Agent: "codex", Memo: big}}}
		if err := Save(path, next); err != nil {
			t.Fatal(err)
		}
		if err := Save(path, first); err != nil {
			t.Fatal(err)
		}
	}
	close(stop)
	wg.Wait()
}

func TestSaveLeavesNoTemporaryFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "restore.json")
	for range 3 {
		if err := Save(path, Snapshot{}); err != nil {
			t.Fatal(err)
		}
	}

	names, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(names) != 1 || names[0].Name() != "restore.json" {
		got := make([]string, 0, len(names))
		for _, n := range names {
			got = append(got, n.Name())
		}
		t.Fatalf("directory = %v, want only restore.json", got)
	}
}

func TestLoadTreatsUnusableFilesAsEmpty(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		name string
		body string
		want string
	}{
		{"corrupt json", "{not json", "parse restore snapshot"},
		{"truncated json", `{"version":1,"sessions":[{"cwd":"/a"`, "parse restore snapshot"},
		{"unknown version", `{"version":99,"sessions":[{"cwd":"/a","agent":"claude"}]}`, "version 99"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, tc.name+".json")
			if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
				t.Fatal(err)
			}

			snap, err := Load(path)

			if err == nil {
				t.Fatal("Load returned no reason for an unusable snapshot")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("reason = %q, want it to mention %q", err, tc.want)
			}
			if len(snap.Sessions) != 0 {
				t.Fatalf("sessions = %+v, want none", snap.Sessions)
			}
			if snap.Version != Version {
				t.Fatalf("version = %d, want the current %d", snap.Version, Version)
			}
		})
	}
}

func TestLoadMissingFileIsEmptyWithReason(t *testing.T) {
	path := filepath.Join(t.TempDir(), "absent.json")

	snap, err := Load(path)

	if err == nil {
		t.Fatal("Load returned no reason for a missing snapshot")
	}
	if !strings.Contains(err.Error(), "no restore snapshot") {
		t.Fatalf("reason = %q, want it to say the snapshot is missing", err)
	}
	if len(snap.Sessions) != 0 {
		t.Fatalf("sessions = %+v, want none", snap.Sessions)
	}
}
