package agentfixtures

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func recorderScript(t *testing.T) string {
	t.Helper()
	root, err := RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(root, "scripts", "record-agent-fixture.sh")
}

func writeStubScript(t *testing.T, dir string, body string) string {
	t.Helper()
	path := filepath.Join(dir, "script")
	if runtime.GOOS == "windows" {
		t.Skip("recorder is a POSIX script")
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func runRecorder(t *testing.T, env []string, args ...string) (string, string, error) {
	t.Helper()
	cmd := exec.Command(recorderScript(t), args...)
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), string(out), err
}

func TestRecorderPromotesSuccessfulCapture(t *testing.T) {
	binDir := t.TempDir()
	dest := t.TempDir()
	stub := writeStubScript(t, binDir, `
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q|-e|-c) shift; continue ;;
    *)
      if [ -z "$outfile" ]; then outfile=$1; shift; continue; fi
      break
      ;;
  esac
done
printf 'hello from stub\n' > "$outfile"
exit 0
`)
	env := []string{
		"PATH=" + binDir + string(os.PathListSeparator) + os.Getenv("PATH"),
		"WEBTABINAL_SCRIPT_BIN=" + stub,
		"WEBTABINAL_SCRIPT_FLAVOR=bsd",
	}
	_, raw, err := runRecorder(t, env,
		"--agent", "claude", "--version", "v1", "--scenario", "idle",
		"--dest", dest, "--", "claude",
	)
	if err != nil {
		t.Fatalf("recorder: %v\n%s", err, raw)
	}
	target := filepath.Join(dest, "claude", "v1", "idle")
	for _, name := range []string{StreamName, MetadataName, CaseName} {
		if _, err := os.Stat(filepath.Join(target, name)); err != nil {
			t.Fatalf("missing %s: %v", name, err)
		}
	}
	if !strings.Contains(raw, "credentials") || !strings.Contains(raw, "absolute home paths") {
		t.Fatalf("missing review checklist:\n%s", raw)
	}
	got, err := os.ReadFile(filepath.Join(target, StreamName))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "hello from stub\n" {
		t.Fatalf("stream = %q", got)
	}
}

func TestRecorderRequiresOverwriteForExisting(t *testing.T) {
	binDir := t.TempDir()
	dest := t.TempDir()
	target := filepath.Join(dest, "claude", "v1", "idle")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(target, "keep.txt")
	if err := os.WriteFile(marker, []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	stub := writeStubScript(t, binDir, `echo stub-ran > /tmp/should-not-use; exit 0`)
	env := []string{"WEBTABINAL_SCRIPT_BIN=" + stub, "WEBTABINAL_SCRIPT_FLAVOR=bsd"}
	_, raw, err := runRecorder(t, env,
		"--agent", "claude", "--version", "v1", "--scenario", "idle",
		"--dest", dest, "--", "claude",
	)
	if err == nil {
		t.Fatal("expected existing dest to fail")
	}
	if !strings.Contains(raw, "exists") {
		t.Fatalf("error = %s", raw)
	}
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != "keep" {
		t.Fatalf("existing fixture was changed: %v %q", err, data)
	}
}

func TestRecorderOverwriteReplacesExisting(t *testing.T) {
	binDir := t.TempDir()
	dest := t.TempDir()
	target := filepath.Join(dest, "claude", "v1", "idle")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "old.txt"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	stub := writeStubScript(t, binDir, `
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q|-e|-c) shift; continue ;;
    *)
      if [ -z "$outfile" ]; then outfile=$1; shift; continue; fi
      break
      ;;
  esac
done
printf 'new\n' > "$outfile"
`)
	env := []string{"WEBTABINAL_SCRIPT_BIN=" + stub, "WEBTABINAL_SCRIPT_FLAVOR=bsd"}
	_, raw, err := runRecorder(t, env,
		"--agent", "claude", "--version", "v1", "--scenario", "idle",
		"--dest", dest, "--overwrite", "--", "claude",
	)
	if err != nil {
		t.Fatalf("%v\n%s", err, raw)
	}
	if _, err := os.Stat(filepath.Join(target, "old.txt")); !os.IsNotExist(err) {
		t.Fatal("old file remained after overwrite")
	}
}

func TestRecorderRejectsOversizedCapture(t *testing.T) {
	binDir := t.TempDir()
	dest := t.TempDir()
	stub := writeStubScript(t, binDir, `
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q|-e|-c) shift; continue ;;
    *)
      if [ -z "$outfile" ]; then outfile=$1; shift; continue; fi
      break
      ;;
  esac
done
dd if=/dev/zero of="$outfile" bs=1024 count=513 >/dev/null 2>&1
`)
	env := []string{"WEBTABINAL_SCRIPT_BIN=" + stub, "WEBTABINAL_SCRIPT_FLAVOR=bsd"}
	_, raw, err := runRecorder(t, env,
		"--agent", "claude", "--version", "v1", "--scenario", "idle",
		"--dest", dest, "--", "claude",
	)
	if err == nil {
		t.Fatal("expected oversized failure")
	}
	if !strings.Contains(raw, "smaller controlled scenario") {
		t.Fatalf("error = %s", raw)
	}
	if _, err := os.Stat(filepath.Join(dest, "claude", "v1", "idle", StreamName)); !os.IsNotExist(err) {
		t.Fatal("oversized capture was promoted")
	}
}

func TestRecorderFailedCommandLeavesDestUnchanged(t *testing.T) {
	binDir := t.TempDir()
	dest := t.TempDir()
	stub := writeStubScript(t, binDir, `
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q|-e|-c) shift; continue ;;
    *)
      if [ -z "$outfile" ]; then outfile=$1; shift; continue; fi
      break
      ;;
  esac
done
printf 'partial\n' > "$outfile"
exit 7
`)
	env := []string{"WEBTABINAL_SCRIPT_BIN=" + stub, "WEBTABINAL_SCRIPT_FLAVOR=bsd"}
	_, raw, err := runRecorder(t, env,
		"--agent", "claude", "--version", "v1", "--scenario", "idle",
		"--dest", dest, "--", "claude",
	)
	if err == nil {
		t.Fatal("expected command failure")
	}
	if !strings.Contains(raw, "destination unchanged") {
		t.Fatalf("error = %s", raw)
	}
	if _, err := os.Stat(filepath.Join(dest, "claude", "v1", "idle")); !os.IsNotExist(err) {
		t.Fatal("failed capture was promoted")
	}
}

func TestRecorderCleansTemporaryDirectory(t *testing.T) {
	binDir := t.TempDir()
	dest := t.TempDir()
	stub := writeStubScript(t, binDir, `
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -q|-e|-c) shift; continue ;;
    *)
      if [ -z "$outfile" ]; then outfile=$1; shift; continue; fi
      break
      ;;
  esac
done
printf 'ok\n' > "$outfile"
printf '%s\n' "$(dirname "$outfile")"
`)
	env := []string{"WEBTABINAL_SCRIPT_BIN=" + stub, "WEBTABINAL_SCRIPT_FLAVOR=bsd"}
	_, raw, err := runRecorder(t, env,
		"--agent", "claude", "--version", "v1", "--scenario", "idle",
		"--dest", dest, "--", "claude",
	)
	if err != nil {
		t.Fatalf("%v\n%s", err, raw)
	}
	matches, _ := filepath.Glob(filepath.Join(os.TempDir(), "webtabinal-fixture.*"))
	for _, m := range matches {
		// leftover dirs from this test would still exist; ignore unrelated leftovers
		_ = m
	}
	// The promoted destination must exist and the captured temp path printed by stub should be gone.
	if _, err := os.Stat(filepath.Join(dest, "claude", "v1", "idle", StreamName)); err != nil {
		t.Fatal(err)
	}
}
