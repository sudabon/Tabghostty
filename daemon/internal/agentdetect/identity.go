package agentdetect

import (
	"path/filepath"
	"sort"
	"strings"
)

type identityHit struct {
	id     string
	rank   int
	signal Signal
}

// Resolve selects a manifest ID from a command line and/or foreground process.
// Precedence is exact executable, then command pattern, then generic.
// Same-rank ties use stable manifest ID order.
func (r *Registry) Resolve(command string, fg ForegroundInfo) (id string, signal Signal) {
	if r == nil {
		return "", SignalNone
	}
	var hits []identityHit
	for _, mid := range r.IDs() {
		if mid == IDGeneric {
			continue
		}
		m, ok := r.Manifest(mid)
		if !ok {
			continue
		}
		if !fg.Failed && exactExecutable(m, fg) {
			hits = append(hits, identityHit{id: m.ID, rank: 0, signal: SignalProcess})
			continue
		}
		if commandMatch(m, command) {
			hits = append(hits, identityHit{id: m.ID, rank: 1, signal: SignalCommand})
		}
	}
	if len(hits) > 0 {
		sort.Slice(hits, func(i, j int) bool {
			if hits[i].rank != hits[j].rank {
				return hits[i].rank < hits[j].rank
			}
			return hits[i].id < hits[j].id
		})
		return hits[0].id, hits[0].signal
	}
	if !fg.Failed && isGenericTUI(fg) {
		if g := r.Generic(); g != nil {
			return g.ID, SignalProcess
		}
	}
	return "", SignalNone
}

func exactExecutable(m *CompiledManifest, fg ForegroundInfo) bool {
	names := make([]string, 0, 1+len(fg.Ancestry))
	if fg.Executable != "" {
		names = append(names, fg.Executable)
	}
	names = append(names, fg.Ancestry...)
	for _, name := range names {
		base := basename(name)
		for _, exe := range m.Executables {
			if exe != "" && base == exe {
				return true
			}
		}
	}
	return false
}

func commandMatch(m *CompiledManifest, command string) bool {
	if command == "" {
		return false
	}
	for _, re := range m.CommandMatchers {
		if re.MatchString(command) {
			return true
		}
	}
	return false
}

func isGenericTUI(fg ForegroundInfo) bool {
	if fg.Failed {
		return false
	}
	if fg.UsingAlt {
		return true
	}
	if !fg.IsShell && strings.TrimSpace(fg.Executable) != "" {
		return true
	}
	return false
}

func basename(name string) string {
	name = strings.TrimSpace(name)
	name = strings.TrimPrefix(name, "-")
	return filepath.Base(name)
}

var shellNames = map[string]bool{
	"zsh": true, "bash": true, "sh": true, "fish": true,
	"dash": true, "ksh": true, "csh": true, "tcsh": true, "nu": true,
}

func isShellName(name string) bool {
	return shellNames[basename(name)]
}
