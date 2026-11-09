package imagedrop

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func pngBytes() []byte {
	// 1x1 transparent PNG.
	return []byte{
		0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
		0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R',
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
		0x89, 0x00, 0x00, 0x00, 0x0a, 'I', 'D', 'A', 'T',
		0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
		0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00,
		0x00, 0x00, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82,
	}
}

func jpegBytes() []byte {
	return append([]byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F'}, make([]byte, 32)...)
}

func gifBytes() []byte {
	return append([]byte("GIF89a"), make([]byte, 32)...)
}

func webpBytes() []byte {
	b := append([]byte("RIFF"), 0x20, 0x00, 0x00, 0x00)
	b = append(b, []byte("WEBPVP8 ")...)
	return append(b, make([]byte, 32)...)
}

func fixedStore(t *testing.T, at time.Time) *Store {
	t.Helper()
	s := New(t.TempDir())
	s.now = func() time.Time { return at }
	n := 0
	s.randRead = func(b []byte) (int, error) {
		for i := range b {
			b[i] = byte(n)
			n++
		}
		return len(b), nil
	}
	return s
}

func TestSaveWritesSniffedExtension(t *testing.T) {
	cases := map[string]struct {
		data []byte
		mime string
		ext  string
	}{
		"png":  {pngBytes(), "image/png", ".png"},
		"jpeg": {jpegBytes(), "image/jpeg", ".jpg"},
		"gif":  {gifBytes(), "image/gif", ".gif"},
		"webp": {webpBytes(), "image/webp", ".webp"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			s := fixedStore(t, time.Date(2026, 8, 24, 15, 30, 12, 0, time.UTC))
			got, err := s.Save(tc.data)
			if err != nil {
				t.Fatalf("save: %v", err)
			}
			if got.MIME != tc.mime {
				t.Errorf("mime = %s, want %s", got.MIME, tc.mime)
			}
			if !strings.HasSuffix(got.Name, tc.ext) {
				t.Errorf("name = %s, want suffix %s", got.Name, tc.ext)
			}
			if got.Bytes != len(tc.data) {
				t.Errorf("bytes = %d, want %d", got.Bytes, len(tc.data))
			}
			if !nameRE.MatchString(got.Name) {
				t.Errorf("name %s does not match the generated-name pattern", got.Name)
			}
			on, err := os.ReadFile(got.Path)
			if err != nil {
				t.Fatalf("read back: %v", err)
			}
			if len(on) != len(tc.data) {
				t.Errorf("wrote %d bytes, want %d", len(on), len(tc.data))
			}
		})
	}
}

// The client's Content-Type never picks the extension; only the bytes do.
func TestSaveRejectsNonImageBytes(t *testing.T) {
	s := fixedStore(t, time.Now())
	for name, data := range map[string][]byte{
		"text":   []byte("#!/bin/sh\nrm -rf /\n"),
		"svg":    []byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>x()</script></svg>`),
		"empty":  {},
		"binary": {0x00, 0x01, 0x02, 0x03},
	} {
		if _, err := s.Save(data); !errors.Is(err, ErrUnsupportedType) {
			t.Errorf("%s: err = %v, want ErrUnsupportedType", name, err)
		}
	}
}

func TestSaveRejectsOversized(t *testing.T) {
	s := fixedStore(t, time.Now())
	big := append(pngBytes(), make([]byte, MaxBytes)...)
	if _, err := s.Save(big); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("err = %v, want ErrTooLarge", err)
	}
	entries, err := os.ReadDir(s.Dir())
	if err == nil && len(entries) != 0 {
		t.Fatalf("rejected upload left %d files behind", len(entries))
	}
}

func TestSaveGeneratesDistinctNamesWithinTheSameSecond(t *testing.T) {
	s := fixedStore(t, time.Date(2026, 8, 24, 15, 30, 12, 0, time.UTC))
	first, err := s.Save(pngBytes())
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Save(pngBytes())
	if err != nil {
		t.Fatal(err)
	}
	if first.Name == second.Name {
		t.Fatalf("two saves in the same second reused %s", first.Name)
	}
}

func TestPruneRemovesOnlyStaleGeneratedFiles(t *testing.T) {
	now := time.Date(2026, 8, 24, 15, 30, 12, 0, time.UTC)
	s := fixedStore(t, now)
	fresh, err := s.Save(pngBytes())
	if err != nil {
		t.Fatal(err)
	}

	stale := filepath.Join(s.Dir(), "img-20260101-101010-deadbeef.png")
	unrelated := filepath.Join(s.Dir(), "notes.txt")
	for _, p := range []string{stale, unrelated} {
		if err := os.WriteFile(p, pngBytes(), 0o600); err != nil {
			t.Fatal(err)
		}
		old := now.Add(-30 * 24 * time.Hour)
		if err := os.Chtimes(p, old, old); err != nil {
			t.Fatal(err)
		}
	}

	removed, err := s.Prune()
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed = %d, want 1", removed)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("stale generated image survived prune")
	}
	if _, err := os.Stat(unrelated); err != nil {
		t.Error("prune deleted a file it did not generate")
	}
	if _, err := os.Stat(fresh.Path); err != nil {
		t.Error("prune deleted a fresh image")
	}
}

func TestPruneOnMissingDirectoryIsNotAnError(t *testing.T) {
	s := New(filepath.Join(t.TempDir(), "never-created"))
	removed, err := s.Prune()
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 0 {
		t.Fatalf("removed = %d, want 0", removed)
	}
}

func TestSaveCreatesDirectoryPrivately(t *testing.T) {
	s := fixedStore(t, time.Now())
	dir := filepath.Join(s.Dir(), "nested")
	s.dir = dir
	saved, err := s.Save(pngBytes())
	if err != nil {
		t.Fatal(err)
	}
	di, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Errorf("dir perm = %o, want 700", perm)
	}
	fi, err := os.Stat(saved.Path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Errorf("file perm = %o, want 600", perm)
	}
}
