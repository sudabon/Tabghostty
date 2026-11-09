package agentdetect

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type rawManifest struct {
	ID               string        `json:"id"`
	DisplayName      string        `json:"display_name"`
	SchemaVersion    int           `json:"schema_version"`
	Match            rawMatch      `json:"match"`
	Screen           rawScreen     `json:"screen"`
	Authority        *rawAuthority `json:"authority"`
	OSCAuthoritative *bool         `json:"osc_authoritative"`
	QuiescenceMS     *int          `json:"quiescence_ms"`
	ActivityWindowMS *int          `json:"activity_window_ms"`
	ActivityMinBytes *int          `json:"activity_min_bytes"`
	VerifiedAgainst  []string      `json:"verified_against"`
	Notes            string        `json:"notes"`
}

type rawMatch struct {
	Executables     []string `json:"executables"`
	CommandPatterns []string `json:"command_patterns"`
}

type rawScreen struct {
	BottomLines *int      `json:"bottom_lines"`
	Buffer      string    `json:"buffer"`
	States      rawStates `json:"states"`
}

type rawStates struct {
	Blocked             patternList `json:"blocked"`
	BlockedSuppressedBy patternList `json:"blocked_suppressed_by"`
	Working             patternList `json:"working"`
	Idle                patternList `json:"idle"`
}

type rawAuthority struct {
	Blocked []string `json:"blocked"`
	Working []string `json:"working"`
	Idle    []string `json:"idle"`
}

type rawPattern struct {
	ID      string `json:"id"`
	Pattern string `json:"pattern"`
}

type patternList []rawPattern

func (p *patternList) UnmarshalJSON(data []byte) error {
	if string(data) == "null" {
		*p = nil
		return nil
	}
	var raws []json.RawMessage
	if err := json.Unmarshal(data, &raws); err != nil {
		return err
	}
	out := make(patternList, 0, len(raws))
	for i, raw := range raws {
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			if strings.TrimSpace(s) == "" {
				return fmt.Errorf("empty pattern at index %d", i)
			}
			out = append(out, rawPattern{Pattern: s})
			continue
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		var obj rawPattern
		if err := dec.Decode(&obj); err != nil {
			return fmt.Errorf("pattern %d: %w", i, err)
		}
		if strings.TrimSpace(obj.Pattern) == "" {
			return fmt.Errorf("empty pattern at index %d", i)
		}
		out = append(out, obj)
	}
	*p = out
	return nil
}

func decodeManifest(file string, data []byte) (*CompiledManifest, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var raw rawManifest
	if err := dec.Decode(&raw); err != nil {
		return nil, &LoadError{File: file, Field: jsonField(err), Err: err}
	}
	if dec.More() {
		return nil, &LoadError{File: file, Field: "", Err: fmt.Errorf("trailing data")}
	}
	m, err := compileManifest(file, raw)
	if err != nil {
		return nil, err
	}
	return m, nil
}

func compileManifest(file string, raw rawManifest) (*CompiledManifest, error) {
	fail := func(field string, err error) error {
		return &LoadError{File: file, Field: field, Err: err}
	}
	if strings.TrimSpace(raw.ID) == "" {
		return nil, fail("id", fmt.Errorf("required"))
	}
	if strings.TrimSpace(raw.DisplayName) == "" {
		return nil, fail("display_name", fmt.Errorf("required"))
	}
	if raw.SchemaVersion != 1 {
		return nil, fail("schema_version", fmt.Errorf("unsupported version %d", raw.SchemaVersion))
	}
	if raw.Authority == nil {
		return nil, fail("authority", fmt.Errorf("required"))
	}

	blockedAuth, err := parseAuthorities("authority.blocked", raw.Authority.Blocked)
	if err != nil {
		return nil, &LoadError{File: file, Field: "authority.blocked", Err: err}
	}
	workingAuth, err := parseAuthorities("authority.working", raw.Authority.Working)
	if err != nil {
		return nil, &LoadError{File: file, Field: "authority.working", Err: err}
	}
	idleAuth, err := parseAuthorities("authority.idle", raw.Authority.Idle)
	if err != nil {
		return nil, &LoadError{File: file, Field: "authority.idle", Err: err}
	}

	if raw.ID == IDGeneric {
		if len(blockedAuth) > 0 {
			return nil, fail("authority.blocked", fmt.Errorf("generic must not grant blocked authority"))
		}
		if len(raw.Screen.States.Blocked) > 0 {
			return nil, fail("screen.states.blocked", fmt.Errorf("generic must not define blocked patterns"))
		}
	}

	buf, err := parseBuffer(raw.Screen.Buffer)
	if err != nil {
		return nil, fail("screen.buffer", err)
	}

	bottom := 15
	if raw.Screen.BottomLines != nil {
		bottom = *raw.Screen.BottomLines
		if bottom < 1 || bottom > 200 {
			return nil, fail("screen.bottom_lines", fmt.Errorf("out of range %d", bottom))
		}
	}

	quiescence := DefaultQuiescence
	if raw.QuiescenceMS != nil {
		if *raw.QuiescenceMS < 1 || *raw.QuiescenceMS > 60_000 {
			return nil, fail("quiescence_ms", fmt.Errorf("out of range %d", *raw.QuiescenceMS))
		}
		quiescence = time.Duration(*raw.QuiescenceMS) * time.Millisecond
	}
	window := DefaultActivityWindow
	if raw.ActivityWindowMS != nil {
		if *raw.ActivityWindowMS < 1 || *raw.ActivityWindowMS > 60_000 {
			return nil, fail("activity_window_ms", fmt.Errorf("out of range %d", *raw.ActivityWindowMS))
		}
		window = time.Duration(*raw.ActivityWindowMS) * time.Millisecond
	}
	minBytes := DefaultActivityMinBytes
	if raw.ActivityMinBytes != nil {
		if *raw.ActivityMinBytes < 1 || *raw.ActivityMinBytes > 1_000_000 {
			return nil, fail("activity_min_bytes", fmt.Errorf("out of range %d", *raw.ActivityMinBytes))
		}
		minBytes = *raw.ActivityMinBytes
	}

	blocked, err := compilePatterns("screen.states.blocked", raw.Screen.States.Blocked)
	if err != nil {
		return nil, &LoadError{File: file, Field: "screen.states.blocked", Err: err}
	}
	blockedSuppress, err := compilePatterns("screen.states.blocked_suppressed_by", raw.Screen.States.BlockedSuppressedBy)
	if err != nil {
		return nil, &LoadError{File: file, Field: "screen.states.blocked_suppressed_by", Err: err}
	}
	working, err := compilePatterns("screen.states.working", raw.Screen.States.Working)
	if err != nil {
		return nil, &LoadError{File: file, Field: "screen.states.working", Err: err}
	}
	idle, err := compilePatterns("screen.states.idle", raw.Screen.States.Idle)
	if err != nil {
		return nil, &LoadError{File: file, Field: "screen.states.idle", Err: err}
	}

	cmds := make([]*regexp.Regexp, 0, len(raw.Match.CommandPatterns))
	for i, pat := range raw.Match.CommandPatterns {
		if strings.TrimSpace(pat) == "" {
			return nil, fail("match.command_patterns", fmt.Errorf("empty pattern at index %d", i))
		}
		re, err := regexp.Compile(pat)
		if err != nil {
			return nil, fail("match.command_patterns", fmt.Errorf("index %d: %w", i, err))
		}
		cmds = append(cmds, re)
	}

	oscAuth := false
	if raw.OSCAuthoritative != nil {
		oscAuth = *raw.OSCAuthoritative
	}

	verified := append([]string(nil), raw.VerifiedAgainst...)
	if raw.ID != IDGeneric && len(verified) == 0 {
		return nil, fail("verified_against", fmt.Errorf("required for dedicated manifests"))
	}

	return &CompiledManifest{
		ID:               raw.ID,
		DisplayName:      raw.DisplayName,
		SchemaVersion:    raw.SchemaVersion,
		Executables:      append([]string(nil), raw.Match.Executables...),
		CommandMatchers:  cmds,
		ScreenBuffer:     buf,
		BottomLines:      bottom,
		HasBottomLines:   raw.Screen.BottomLines != nil,
		Blocked:          blocked,
		BlockedSuppress:  blockedSuppress,
		Working:          working,
		Idle:             idle,
		BlockedAuth:      blockedAuth,
		WorkingAuth:      workingAuth,
		IdleAuth:         idleAuth,
		OSCAuthoritative: oscAuth,
		Quiescence:       quiescence,
		HasQuiescence:    raw.QuiescenceMS != nil,
		ActivityWindow:   window,
		ActivityMinBytes: minBytes,
		VerifiedAgainst:  verified,
		Notes:            raw.Notes,
	}, nil
}

func parseAuthorities(field string, in []string) ([]Authority, error) {
	out := make([]Authority, 0, len(in))
	for _, s := range in {
		a := Authority(s)
		switch a {
		case AuthorityScreen, AuthorityActivity, AuthorityOSC, AuthorityScreenQuiescence:
			out = append(out, a)
		default:
			return nil, fmt.Errorf("%s: invalid enum %q", field, s)
		}
	}
	return out, nil
}

func parseBuffer(s string) (vtscreen.BufferKind, error) {
	switch s {
	case "", "active":
		return vtscreen.BufferActive, nil
	case "primary":
		return vtscreen.BufferPrimary, nil
	case "alternate", "alt":
		return vtscreen.BufferAlternate, nil
	default:
		return "", fmt.Errorf("invalid enum %q", s)
	}
}

func compilePatterns(field string, in patternList) ([]CompiledPattern, error) {
	out := make([]CompiledPattern, 0, len(in))
	for i, p := range in {
		if strings.TrimSpace(p.Pattern) == "" {
			return nil, fmt.Errorf("%s: empty pattern at index %d", field, i)
		}
		re, err := regexp.Compile(p.Pattern)
		if err != nil {
			return nil, fmt.Errorf("%s: index %d: %w", field, i, err)
		}
		id := p.ID
		if id == "" {
			id = fmt.Sprintf("%s.%d", strings.TrimPrefix(field, "screen.states."), i)
		}
		out = append(out, CompiledPattern{ID: id, RE: re})
	}
	return out, nil
}

func jsonField(err error) string {
	msg := err.Error()
	const prefix = "json: unknown field "
	if strings.HasPrefix(msg, prefix) {
		return strings.Trim(strings.TrimPrefix(msg, prefix), `"`)
	}
	return ""
}
