package agentdetect

import (
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

// Diagnostic is a read-only view of a session's screen and agent-match state.
type Diagnostic struct {
	SessionID         string              `json:"session_id"`
	Buffer            vtscreen.BufferKind `json:"buffer"`
	Cols              int                 `json:"cols"`
	Rows              int                 `json:"rows"`
	Lines             []string            `json:"lines"`
	ModelAvailable    bool                `json:"model_available"`
	DetectorAvailable bool                `json:"detector_available"`
	Agent             DiagnosticAgent     `json:"agent"`
	Manifest          DiagnosticManifest  `json:"manifest"`
	Matches           DiagnosticMatches   `json:"matches"`
}

// DiagnosticAgent is the current detector snapshot without hidden match text.
type DiagnosticAgent struct {
	ID     string `json:"id"`
	State  string `json:"state"`
	Since  string `json:"since,omitempty"`
	Signal string `json:"signal"`
	Detail string `json:"detail,omitempty"`
}

// DiagnosticManifest identifies the selected bundled/local manifest.
type DiagnosticManifest struct {
	ID               string   `json:"id,omitempty"`
	DisplayName      string   `json:"display_name,omitempty"`
	VerifiedAgainst  []string `json:"verified_against,omitempty"`
	OSCAuthoritative bool     `json:"osc_authoritative"`
}

// DiagnosticMatches lists pattern IDs and line indexes per state.
type DiagnosticMatches struct {
	Blocked []DiagnosticHit `json:"blocked"`
	Working []DiagnosticHit `json:"working"`
	Idle    []DiagnosticHit `json:"idle"`
}

// DiagnosticHit names a matched pattern. It never includes the substring.
type DiagnosticHit struct {
	ID   string `json:"id"`
	Line int    `json:"line"`
}

// BuildDiagnostic combines a bounded screen snapshot with the current detector
// observation. It does not mutate detector or session state.
func BuildDiagnostic(sessionID string, screen vtscreen.Snapshot, agent Snapshot, detectorOK bool, reg *Registry) Diagnostic {
	out := Diagnostic{
		SessionID:         sessionID,
		Buffer:            screen.Buffer,
		Cols:              screen.Cols,
		Rows:              screen.Rows,
		Lines:             append([]string(nil), screen.Lines...),
		ModelAvailable:    screen.Available,
		DetectorAvailable: detectorOK,
		Matches: DiagnosticMatches{
			Blocked: []DiagnosticHit{},
			Working: []DiagnosticHit{},
			Idle:    []DiagnosticHit{},
		},
	}
	if detectorOK {
		out.Agent = DiagnosticAgent{
			ID:     agent.AgentID,
			State:  string(agent.State),
			Signal: string(agent.Signal),
			Detail: agent.Detail,
		}
		if !agent.Since.IsZero() {
			out.Agent.Since = agent.Since.UTC().Format(time.RFC3339)
		}
		if reg != nil && agent.AgentID != "" {
			if man, ok := reg.Manifest(agent.AgentID); ok {
				out.Manifest = DiagnosticManifest{
					ID:               man.ID,
					DisplayName:      man.DisplayName,
					VerifiedAgainst:  append([]string(nil), man.VerifiedAgainst...),
					OSCAuthoritative: man.OSCAuthoritative,
				}
				for _, hit := range MatchManifest(man, out.Lines) {
					item := DiagnosticHit{ID: hit.ID, Line: hit.Line}
					switch hit.State {
					case StateBlocked:
						out.Matches.Blocked = append(out.Matches.Blocked, item)
					case StateWorking:
						out.Matches.Working = append(out.Matches.Working, item)
					case StateIdle:
						out.Matches.Idle = append(out.Matches.Idle, item)
					}
				}
			}
		}
	}
	return out
}
