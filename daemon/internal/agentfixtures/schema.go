package agentfixtures

import (
	"fmt"
	"strings"
)

const (
	// SchemaVersion is the fixture metadata/case schema.
	SchemaVersion = 1
	// MaxFileBytes is the per-file size limit for stream.raw, case.json, and metadata.json.
	MaxFileBytes = 512 * 1024
	// CaptureToolVersion is written by scripts/record-agent-fixture.sh.
	CaptureToolVersion = "record-agent-fixture/1"
	// StreamName is the raw PTY capture filename.
	StreamName = "stream.raw"
	// MetadataName is the capture metadata filename.
	MetadataName = "metadata.json"
	// CaseName is the expected timeline filename.
	CaseName = "case.json"
)

// Metadata is capture-time information for one scenario directory.
type Metadata struct {
	SchemaVersion      int             `json:"schema_version"`
	Agent              string          `json:"agent"`
	Version            string          `json:"version"`
	Scenario           string          `json:"scenario"`
	Rows               int             `json:"rows"`
	Columns            int             `json:"columns"`
	TERM               string          `json:"term"`
	Locale             string          `json:"locale"`
	Platform           string          `json:"platform"`
	CaptureToolVersion string          `json:"capture_tool_version"`
	Reviewed           bool            `json:"reviewed"`
	OSC                *OSCObservation `json:"osc,omitempty"`
	Notes              string          `json:"notes,omitempty"`
}

// OSCObservation records whether notification OSC appeared in the capture.
type OSCObservation struct {
	OSC0   bool `json:"osc0"`
	OSC9   bool `json:"osc9"`
	OSC99  bool `json:"osc99"`
	OSC777 bool `json:"osc777"`
}

// CaseFile maps byte ranges and virtual time to expected detector observations.
type CaseFile struct {
	SchemaVersion int      `json:"schema_version"`
	Identity      Identity `json:"identity"`
	Steps         []Step   `json:"steps"`
}

// Identity tells the harness how to select a bundled manifest.
type Identity struct {
	Command    string `json:"command"`
	Executable string `json:"executable,omitempty"`
}

// Step is one feed of stream bytes plus a fake-clock advance.
type Step struct {
	Name        string   `json:"name"`
	ByteStart   int      `json:"byte_start"`
	ByteEnd     int      `json:"byte_end"`
	AdvanceMS   int      `json:"advance_ms"`
	OutputBytes *int     `json:"output_bytes,omitempty"`
	Expect      Expect   `json:"expect"`
	BottomLines []string `json:"bottom_lines,omitempty"`
}

// Expect is the detector observation after the step's virtual time has elapsed.
type Expect struct {
	AgentID     string `json:"agent_id"`
	State       string `json:"state"`
	Signal      string `json:"signal"`
	ChangeCount *int   `json:"change_count,omitempty"`
}

// Fixture is a validated scenario ready for replay.
type Fixture struct {
	Dir      string
	Agent    string
	Version  string
	Scenario string
	Meta     Metadata
	Case     CaseFile
	Stream   []byte
}

func (m Metadata) validate() error {
	if m.SchemaVersion != SchemaVersion {
		return fmt.Errorf("schema_version: want %d, got %d", SchemaVersion, m.SchemaVersion)
	}
	for _, pair := range []struct {
		name, val string
	}{
		{"agent", m.Agent},
		{"version", m.Version},
		{"scenario", m.Scenario},
		{"term", m.TERM},
		{"locale", m.Locale},
		{"platform", m.Platform},
		{"capture_tool_version", m.CaptureToolVersion},
	} {
		if strings.TrimSpace(pair.val) == "" {
			return fmt.Errorf("%s: required", pair.name)
		}
	}
	if m.Rows < 1 || m.Rows > 200 {
		return fmt.Errorf("rows: out of range %d", m.Rows)
	}
	if m.Columns < 1 || m.Columns > 500 {
		return fmt.Errorf("columns: out of range %d", m.Columns)
	}
	return nil
}

func (c CaseFile) validate(streamLen int, meta Metadata) error {
	if c.SchemaVersion != SchemaVersion {
		return fmt.Errorf("schema_version: want %d, got %d", SchemaVersion, c.SchemaVersion)
	}
	if strings.TrimSpace(c.Identity.Command) == "" && strings.TrimSpace(c.Identity.Executable) == "" {
		return fmt.Errorf("identity: command or executable is required")
	}
	if len(c.Steps) == 0 {
		return fmt.Errorf("steps: required")
	}
	for i, step := range c.Steps {
		if err := step.validate(streamLen); err != nil {
			return fmt.Errorf("steps[%d]: %w", i, err)
		}
	}
	_ = meta
	return nil
}

func (s Step) validate(streamLen int) error {
	if strings.TrimSpace(s.Name) == "" {
		return fmt.Errorf("name: required")
	}
	if s.ByteStart < 0 || s.ByteEnd < 0 {
		return fmt.Errorf("byte range must be non-negative")
	}
	if s.ByteStart > s.ByteEnd {
		return fmt.Errorf("byte_start %d > byte_end %d", s.ByteStart, s.ByteEnd)
	}
	if s.ByteEnd > streamLen {
		return fmt.Errorf("byte_end %d exceeds stream length %d", s.ByteEnd, streamLen)
	}
	if s.AdvanceMS < 0 || s.AdvanceMS > 60_000 {
		return fmt.Errorf("advance_ms: out of range %d", s.AdvanceMS)
	}
	if s.OutputBytes != nil && (*s.OutputBytes < 0 || *s.OutputBytes > MaxFileBytes) {
		return fmt.Errorf("output_bytes: out of range %d", *s.OutputBytes)
	}
	if err := s.Expect.validate(); err != nil {
		return fmt.Errorf("expect: %w", err)
	}
	return nil
}

func (e Expect) validate() error {
	if strings.TrimSpace(e.AgentID) == "" {
		return fmt.Errorf("agent_id: required")
	}
	switch e.State {
	case "none", "idle", "working", "blocked":
	default:
		return fmt.Errorf("state: invalid enum %q", e.State)
	}
	switch e.Signal {
	case "", "screen", "activity", "osc", "command", "process", "fallback":
	default:
		return fmt.Errorf("signal: invalid enum %q", e.Signal)
	}
	if e.ChangeCount != nil && *e.ChangeCount < 0 {
		return fmt.Errorf("change_count: negative")
	}
	return nil
}

func (s Step) ActivityBytes() int {
	if s.OutputBytes != nil {
		return *s.OutputBytes
	}
	return s.ByteEnd - s.ByteStart
}
