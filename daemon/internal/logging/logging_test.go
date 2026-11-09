package logging

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRotatingWriterRecoversAfterReopenFailure(t *testing.T) {
	dir := t.TempDir()
	w := &rotatingWriter{path: filepath.Join(dir, "daemon.log"), maxBytes: 1}
	if _, err := w.Write([]byte("a")); err != nil {
		t.Fatal(err)
	}
	missingDir := filepath.Join(dir, "missing")
	w.path = filepath.Join(missingDir, "daemon.log")
	if _, err := w.Write([]byte("b")); err == nil {
		t.Fatal("rotation unexpectedly reopened a file in a missing directory")
	}
	if err := os.Mkdir(missingDir, 0o755); err != nil {
		t.Fatal(err)
	}
	w.maxBytes = 100

	if _, err := w.Write([]byte("c")); err != nil {
		t.Fatalf("writer did not recover after path became available: %v", err)
	}
}
