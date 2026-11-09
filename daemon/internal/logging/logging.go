package logging

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"

	"github.com/sudabon/webtabinal/internal/paths"
)

const maxLogBytes = 5 * 1024 * 1024

type rotatingWriter struct {
	mu       sync.Mutex
	path     string
	file     *os.File
	written  int64
	maxBytes int64
}

func (w *rotatingWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file == nil {
		if err := w.openLocked(); err != nil {
			return 0, err
		}
	}
	if w.written+int64(len(p)) > w.maxBytes {
		_ = w.file.Close()
		w.file = nil
		rotated := w.path + ".1"
		_ = os.Remove(rotated)
		_ = os.Rename(w.path, rotated)
		if err := w.openLocked(); err != nil {
			return 0, err
		}
	}
	n, err := w.file.Write(p)
	w.written += int64(n)
	return n, err
}

func (w *rotatingWriter) openLocked() error {
	f, err := os.OpenFile(w.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return err
	}
	w.file = f
	w.written = info.Size()
	return nil
}

func Setup() (*log.Logger, error) {
	dir, err := paths.LogsDir()
	if err != nil {
		return nil, err
	}
	if err := paths.EnsureDir(dir); err != nil {
		return nil, err
	}
	path, err := paths.LogPath()
	if err != nil {
		return nil, err
	}
	rw := &rotatingWriter{path: path, maxBytes: maxLogBytes}
	multi := io.MultiWriter(os.Stderr, rw)
	logger := log.New(multi, "", log.LstdFlags|log.Lmsgprefix)
	logger.SetPrefix(fmt.Sprintf("[%s] ", paths.AppName))
	_ = filepath.Clean(path)
	return logger, nil
}
