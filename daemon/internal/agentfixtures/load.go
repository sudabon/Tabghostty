package agentfixtures

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Discover walks root for agent/version/scenario directories and validates them.
func Discover(root string) ([]Fixture, error) {
	if root == "" {
		return nil, fmt.Errorf("fixture root is empty")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("fixture root %s: %w", root, err)
		}
		return nil, err
	}
	var out []Fixture
	var first error
	for _, agentEnt := range sortedDirs(entries) {
		agentDir := filepath.Join(root, agentEnt.Name())
		versions, err := os.ReadDir(agentDir)
		if err != nil {
			first = appendErr(first, err)
			continue
		}
		for _, verEnt := range sortedDirs(versions) {
			verDir := filepath.Join(agentDir, verEnt.Name())
			scenarios, err := os.ReadDir(verDir)
			if err != nil {
				first = appendErr(first, err)
				continue
			}
			for _, scEnt := range sortedDirs(scenarios) {
				dir := filepath.Join(verDir, scEnt.Name())
				fx, err := Load(dir)
				if err != nil {
					first = appendErr(first, fmt.Errorf("%s: %w", dir, err))
					continue
				}
				out = append(out, fx)
			}
		}
	}
	if first != nil {
		return out, first
	}
	return out, nil
}

// Load validates and reads one scenario directory.
func Load(dir string) (Fixture, error) {
	metaBytes, err := readLimited(filepath.Join(dir, MetadataName))
	if err != nil {
		return Fixture{}, err
	}
	caseBytes, err := readLimited(filepath.Join(dir, CaseName))
	if err != nil {
		return Fixture{}, err
	}
	stream, err := readLimited(filepath.Join(dir, StreamName))
	if err != nil {
		return Fixture{}, err
	}
	meta, err := decodeMetadata(metaBytes)
	if err != nil {
		return Fixture{}, fmt.Errorf("%s: %w", MetadataName, err)
	}
	caseFile, err := decodeCase(caseBytes)
	if err != nil {
		return Fixture{}, fmt.Errorf("%s: %w", CaseName, err)
	}
	if err := meta.validate(); err != nil {
		return Fixture{}, fmt.Errorf("%s: %w", MetadataName, err)
	}
	if err := caseFile.validate(len(stream), meta); err != nil {
		return Fixture{}, fmt.Errorf("%s: %w", CaseName, err)
	}
	baseAgent := filepath.Base(filepath.Dir(filepath.Dir(dir)))
	baseVer := filepath.Base(filepath.Dir(dir))
	baseSc := filepath.Base(dir)
	if meta.Agent != baseAgent || meta.Version != baseVer || meta.Scenario != baseSc {
		return Fixture{}, fmt.Errorf("metadata agent/version/scenario %s/%s/%s does not match directory %s/%s/%s",
			meta.Agent, meta.Version, meta.Scenario, baseAgent, baseVer, baseSc)
	}
	return Fixture{
		Dir:      dir,
		Agent:    meta.Agent,
		Version:  meta.Version,
		Scenario: meta.Scenario,
		Meta:     meta,
		Case:     caseFile,
		Stream:   stream,
	}, nil
}

func decodeMetadata(data []byte) (Metadata, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var meta Metadata
	if err := dec.Decode(&meta); err != nil {
		return Metadata{}, err
	}
	if dec.More() {
		return Metadata{}, fmt.Errorf("trailing data")
	}
	return meta, nil
}

func decodeCase(data []byte) (CaseFile, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var c CaseFile
	if err := dec.Decode(&c); err != nil {
		return CaseFile{}, err
	}
	if dec.More() {
		return CaseFile{}, fmt.Errorf("trailing data")
	}
	return c, nil
}

func readLimited(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.IsDir() {
		return nil, fmt.Errorf("%s is a directory", path)
	}
	if info.Size() > MaxFileBytes {
		return nil, fmt.Errorf("%s: size %d exceeds limit %d; capture a smaller controlled scenario", filepath.Base(path), info.Size(), MaxFileBytes)
	}
	return os.ReadFile(path)
}

func sortedDirs(entries []os.DirEntry) []os.DirEntry {
	var dirs []os.DirEntry
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			dirs = append(dirs, e)
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return dirs[i].Name() < dirs[j].Name() })
	return dirs
}

func appendErr(first, next error) error {
	if first == nil {
		return next
	}
	return fmt.Errorf("%v; %w", first, next)
}
