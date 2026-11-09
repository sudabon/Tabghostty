package agentdetect

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/sudabon/webtabinal/internal/paths"
)

// LoadError identifies a manifest file and field without including screen text.
type LoadError struct {
	File  string
	Field string
	Err   error
}

func (e *LoadError) Error() string {
	if e == nil {
		return ""
	}
	if e.Field != "" {
		return fmt.Sprintf("%s: %s: %v", e.File, e.Field, e.Err)
	}
	return fmt.Sprintf("%s: %v", e.File, e.Err)
}

func (e *LoadError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// Registry is an immutable startup snapshot of compiled manifests.
type Registry struct {
	order       []string
	byID        map[string]*CompiledManifest
	unavailable map[string]error
	errors      []error
}

// LoadOptions controls bundled and local manifest sources.
type LoadOptions struct {
	Bundled      fs.FS
	LocalDir     string
	DisableLocal bool
	Logger       *log.Logger
}

// DefaultManifestDir is ~/Library/Application Support/WebTabinal/manifests.
func DefaultManifestDir() (string, error) {
	return paths.ManifestsDir()
}

// Load builds an immutable registry from embedded assets and optional local overrides.
func Load(opts LoadOptions) *Registry {
	reg := &Registry{
		byID:        map[string]*CompiledManifest{},
		unavailable: map[string]error{},
	}
	bundled := opts.Bundled
	if bundled == nil {
		bundled = bundledFS
	}
	if err := loadFS(reg, bundled, "bundled"); err != nil {
		reg.errors = append(reg.errors, err)
	}

	if !opts.DisableLocal {
		dir := opts.LocalDir
		if dir == "" {
			var err error
			dir, err = DefaultManifestDir()
			if err != nil {
				reg.errors = append(reg.errors, err)
				return reg.freeze()
			}
		}
		if err := loadLocal(reg, dir); err != nil {
			reg.errors = append(reg.errors, err)
		}
	}
	reg.freeze()
	if opts.Logger != nil {
		for _, err := range reg.errors {
			opts.Logger.Printf("agentdetect: %v", err)
		}
	}
	return reg
}

func (r *Registry) freeze() *Registry {
	ids := make([]string, 0, len(r.byID))
	for id := range r.byID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	r.order = ids
	return r
}

func loadFS(reg *Registry, fsys fs.FS, source string) error {
	matches, err := fs.Glob(fsys, "manifests/*.json")
	if err != nil {
		return err
	}
	if len(matches) == 0 {
		matches, err = fs.Glob(fsys, "*.json")
		if err != nil {
			return err
		}
	}
	sort.Strings(matches)
	var first error
	seen := map[string]string{}
	for _, name := range matches {
		data, err := fs.ReadFile(fsys, name)
		if err != nil {
			first = appendErr(first, err)
			continue
		}
		label := source + ":" + filepath.Base(name)
		m, err := decodeManifest(label, data)
		if err != nil {
			first = appendErr(first, err)
			continue
		}
		if prev, ok := seen[m.ID]; ok {
			err := &LoadError{File: label, Field: "id", Err: fmt.Errorf("duplicate id %q (also %s)", m.ID, prev)}
			first = appendErr(first, err)
			continue
		}
		seen[m.ID] = label
		reg.byID[m.ID] = m
	}
	return first
}

func loadLocal(reg *Registry, dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	var first error
	seen := map[string]string{}
	for _, ent := range entries {
		if ent.IsDir() || !strings.HasSuffix(strings.ToLower(ent.Name()), ".json") {
			continue
		}
		path := filepath.Join(dir, ent.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			first = appendErr(first, err)
			continue
		}
		m, err := decodeManifest(path, data)
		if err != nil {
			id := peekID(data)
			if id != "" {
				delete(reg.byID, id)
				reg.unavailable[id] = err
			}
			first = appendErr(first, err)
			continue
		}
		if prev, ok := seen[m.ID]; ok {
			err := &LoadError{File: path, Field: "id", Err: fmt.Errorf("duplicate id %q (also %s)", m.ID, prev)}
			delete(reg.byID, m.ID)
			reg.unavailable[m.ID] = err
			first = appendErr(first, err)
			continue
		}
		seen[m.ID] = path
		delete(reg.unavailable, m.ID)
		reg.byID[m.ID] = m
	}
	return first
}

func peekID(data []byte) string {
	var probe struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(data, &probe)
	return probe.ID
}

func appendErr(first, next error) error {
	if first == nil {
		return next
	}
	return fmt.Errorf("%v; %w", first, next)
}

// Manifest returns a compiled manifest if it is available (not suppressed).
func (r *Registry) Manifest(id string) (*CompiledManifest, bool) {
	if r == nil || id == "" {
		return nil, false
	}
	if _, bad := r.unavailable[id]; bad {
		return nil, false
	}
	m, ok := r.byID[id]
	return m, ok
}

// Generic returns the generic fallback manifest when available.
func (r *Registry) Generic() *CompiledManifest {
	m, _ := r.Manifest(IDGeneric)
	return m
}

// IDs returns available manifest IDs in stable order.
func (r *Registry) IDs() []string {
	if r == nil {
		return nil
	}
	out := make([]string, 0, len(r.order))
	for _, id := range r.order {
		if _, bad := r.unavailable[id]; bad {
			continue
		}
		if _, ok := r.byID[id]; ok {
			out = append(out, id)
		}
	}
	return out
}

// Errors returns load-time validation and override errors.
func (r *Registry) Errors() []error {
	if r == nil {
		return nil
	}
	return append([]error(nil), r.errors...)
}

// Unavailable reports why a manifest ID was suppressed.
func (r *Registry) Unavailable(id string) error {
	if r == nil {
		return nil
	}
	return r.unavailable[id]
}
