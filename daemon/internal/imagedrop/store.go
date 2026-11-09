// Package imagedrop turns an image handed over by the browser into a file on
// disk. Coding agents (Claude Code, Codex, cursor-agent) accept an image only
// as a filesystem path, so a pasted or dropped image has to exist as a real
// file before its path can be typed into the PTY.
package imagedrop

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// MaxBytes caps one upload. Agents downscale large images anyway, and the
// bytes travel through a JSON-free but still in-memory request body.
const MaxBytes = 10 << 20

// DefaultRetention is how long a saved image stays on disk. An agent may
// re-read an image when a session is resumed, so this outlives a working day
// by a wide margin while still bounding the directory.
const DefaultRetention = 7 * 24 * time.Hour

// ErrUnsupportedType is returned for bytes that are not one of the image
// formats every supported agent can read.
var ErrUnsupportedType = errors.New("unsupported image type")

// ErrTooLarge is returned for uploads above MaxBytes.
var ErrTooLarge = errors.New("image exceeds size limit")

// extByMIME lists the formats all three agents read. SVG is deliberately
// absent: it is a script container, and no agent needs it.
var extByMIME = map[string]string{
	"image/png":  ".png",
	"image/jpeg": ".jpg",
	"image/gif":  ".gif",
	"image/webp": ".webp",
}

// nameRE matches only the names Save generates. Prune deletes nothing else,
// so a mis-pointed directory cannot lose unrelated files.
var nameRE = regexp.MustCompile(`^img-\d{8}-\d{6}-[0-9a-f]{8}\.(png|jpg|gif|webp)$`)

// Saved describes one stored image.
type Saved struct {
	Path  string `json:"path"`
	Name  string `json:"name"`
	MIME  string `json:"mime"`
	Bytes int    `json:"bytes"`
}

// Store writes images into a single directory and prunes stale ones.
type Store struct {
	dir       string
	retention time.Duration
	now       func() time.Time
	randRead  func([]byte) (int, error)
}

// New returns a store rooted at dir. The directory is created on first save.
func New(dir string) *Store {
	return &Store{
		dir:       dir,
		retention: DefaultRetention,
		now:       time.Now,
		randRead:  rand.Read,
	}
}

// Dir reports the directory images are written to.
func (s *Store) Dir() string { return s.dir }

// Save sniffs data, writes it under a generated name, and prunes stale files.
// The content type comes from the bytes, never from the client, so a mislabelled
// or hostile upload cannot choose its own extension.
func (s *Store) Save(data []byte) (Saved, error) {
	if len(data) > MaxBytes {
		return Saved{}, ErrTooLarge
	}
	if len(data) == 0 {
		return Saved{}, ErrUnsupportedType
	}
	mime := sniffMIME(data)
	ext, ok := extByMIME[mime]
	if !ok {
		return Saved{}, ErrUnsupportedType
	}
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return Saved{}, err
	}
	name, err := s.newName(ext)
	if err != nil {
		return Saved{}, err
	}
	path := filepath.Join(s.dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return Saved{}, err
	}
	// Best effort: a full disk is worth reporting, an unprunable stale file is not.
	_, _ = s.Prune()
	return Saved{Path: path, Name: name, MIME: mime, Bytes: len(data)}, nil
}

// Prune removes generated images older than the retention window and reports
// how many were deleted. A missing directory is not an error.
func (s *Store) Prune() (int, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	cutoff := s.now().Add(-s.retention)
	removed := 0
	var firstErr error
	for _, e := range entries {
		if e.IsDir() || !nameRE.MatchString(e.Name()) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if !info.ModTime().Before(cutoff) {
			continue
		}
		if err := os.Remove(filepath.Join(s.dir, e.Name())); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		removed++
	}
	return removed, firstErr
}

func (s *Store) newName(ext string) (string, error) {
	var buf [4]byte
	if _, err := s.randRead(buf[:]); err != nil {
		return "", err
	}
	return fmt.Sprintf("img-%s-%s%s", s.now().Format("20060102-150405"), hex.EncodeToString(buf[:]), ext), nil
}

// sniffMIME reports the media type of data. http.DetectContentType covers
// every format in extByMIME and returns something harmless for the rest.
func sniffMIME(data []byte) string {
	ct := http.DetectContentType(data)
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		ct = ct[:i]
	}
	return strings.TrimSpace(ct)
}
