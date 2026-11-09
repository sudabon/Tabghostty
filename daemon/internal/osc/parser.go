package osc

import (
	"encoding/base64"
	"net/url"
	"strconv"
	"strings"
)

type EventKind int

const (
	EventNone EventKind = iota
	EventCWD
	EventCmdStart
	EventCmdEnd
	EventPrompt
	EventNotify
	EventColorQuery
	EventShellExit
)

type Event struct {
	Kind         EventKind
	CWD          string
	Command      string
	ExitCode     *int
	Title        string
	Body         string
	ColorIndexes []int
	OSC          int
}

// Parser scans a byte stream for OSC sequences and returns events.
// It does not strip sequences; callers forward original bytes unchanged.
type Parser struct {
	buf []byte
}

func (p *Parser) Feed(data []byte) []Event {
	p.buf = append(p.buf, data...)
	var events []Event
	for {
		start := indexOSC(p.buf)
		if start < 0 {
			if len(p.buf) > 8192 {
				p.buf = append([]byte(nil), p.buf[len(p.buf)-4096:]...)
			}
			return events
		}
		if start > 0 {
			p.buf = p.buf[start:]
		}
		end := indexOSCEnd(p.buf)
		if end < 0 {
			if len(p.buf) > 8192 {
				p.buf = nil
			}
			return events
		}
		payload := string(p.buf[2:end]) // after ESC ]
		p.buf = p.buf[end+termLen(p.buf[end:]):]
		if ev, ok := parseOSC(payload); ok {
			events = append(events, ev)
		}
	}
}

func indexOSC(b []byte) int {
	for i := 0; i+1 < len(b); i++ {
		if b[i] == 0x1b && b[i+1] == ']' {
			return i
		}
	}
	return -1
}

func indexOSCEnd(b []byte) int {
	for i := 2; i < len(b); i++ {
		if b[i] == 0x07 { // BEL
			return i
		}
		if b[i] == 0x1b && i+1 < len(b) && b[i+1] == '\\' { // ST
			return i
		}
	}
	return -1
}

func termLen(b []byte) int {
	if len(b) == 0 {
		return 0
	}
	if b[0] == 0x07 {
		return 1
	}
	if b[0] == 0x1b {
		return 2
	}
	return 1
}

func parseOSC(payload string) (Event, bool) {
	if ids, ok := parseColorQueries(payload); ok {
		return Event{Kind: EventColorQuery, ColorIndexes: ids}, true
	}
	// OSC 7 ; file://...
	if strings.HasPrefix(payload, "7;") {
		raw := strings.TrimPrefix(payload, "7;")
		cwd := parseFileURL(raw)
		if cwd == "" {
			return Event{}, false
		}
		return Event{Kind: EventCWD, CWD: cwd}, true
	}
	// OSC 133 ; A|B|C|D[;exit]
	if strings.HasPrefix(payload, "133;") {
		rest := strings.TrimPrefix(payload, "133;")
		parts := strings.SplitN(rest, ";", 2)
		switch parts[0] {
		case "A":
			return Event{Kind: EventPrompt}, true
		case "C":
			return Event{Kind: EventCmdStart}, true
		case "D":
			var code *int
			if len(parts) > 1 && parts[1] != "" {
				if v, err := strconv.Atoi(parts[1]); err == nil {
					code = &v
				}
			}
			return Event{Kind: EventCmdEnd, ExitCode: code}, true
		}
		return Event{}, false
	}
	// OSC 9973 ; cmd ; base64  |  OSC 9973 ; exit [; code]
	if strings.HasPrefix(payload, "9973;") {
		return parseOSC9973(strings.TrimPrefix(payload, "9973;"))
	}
	// OSC 777 ; notify ; title ; body  (urxvt / iTerm-style desktop notification)
	if strings.HasPrefix(payload, "777;") {
		return parseOSC777(strings.TrimPrefix(payload, "777;"))
	}
	// OSC 99 ; [metadata;]payload  (Kitty desktop notification; check before OSC 9)
	if strings.HasPrefix(payload, "99;") {
		return parseOSC99(strings.TrimPrefix(payload, "99;"))
	}
	// OSC 9 ; message  (iTerm2 Growl)
	if strings.HasPrefix(payload, "9;") {
		body := strings.TrimPrefix(payload, "9;")
		if strings.TrimSpace(body) == "" {
			return Event{}, false
		}
		if isConEmuSubcommand(body) {
			return Event{}, false
		}
		return Event{Kind: EventNotify, Body: body, OSC: 9}, true
	}
	return Event{}, false
}

// parseOSC9973 handles the WebTabinal private OSC. Unrecognised subtypes yield
// no event so that adding one later cannot disturb existing session fields.
func parseOSC9973(rest string) (Event, bool) {
	subtype, arg, hasArg := strings.Cut(rest, ";")
	switch subtype {
	case "cmd":
		if !hasArg {
			return Event{}, false
		}
		decoded, err := base64.StdEncoding.DecodeString(arg)
		if err != nil {
			return Event{}, false
		}
		return Event{Kind: EventCmdStart, Command: string(decoded)}, true
	case "exit":
		// The status is carried for diagnostics only; a missing or malformed
		// value still signals that the shell terminated on its own.
		ev := Event{Kind: EventShellExit}
		if hasArg {
			if v, err := strconv.Atoi(arg); err == nil {
				ev.ExitCode = &v
			}
		}
		return ev, true
	}
	return Event{}, false
}

// isConEmuSubcommand reports whether an OSC 9 body is a ConEmu extension
// rather than a notification: 9;4 is a progress report and 9;9 is a working
// directory report. Neither asks for the user's attention.
func isConEmuSubcommand(body string) bool {
	return strings.HasPrefix(body, "4;") || strings.HasPrefix(body, "9;")
}

func parseOSC99(rest string) (Event, bool) {
	metadata, text, found := strings.Cut(rest, ";")
	if !found {
		text = metadata
		metadata = ""
	}
	params := parseKittyParams(metadata)
	ev := Event{Kind: EventNotify, OSC: 99}
	switch params["p"] {
	case "title":
		ev.Title = text
	default:
		ev.Body = text
	}
	if strings.TrimSpace(ev.Title) == "" && strings.TrimSpace(ev.Body) == "" {
		return Event{}, false
	}
	return ev, true
}

func parseOSC777(rest string) (Event, bool) {
	parts := strings.SplitN(rest, ";", 3)
	if len(parts) > 0 && parts[0] == "notify" {
		parts = parts[1:]
	}
	ev := Event{Kind: EventNotify, OSC: 777}
	switch len(parts) {
	case 0:
		return Event{}, false
	case 1:
		ev.Body = parts[0]
	case 2:
		ev.Title = parts[0]
		ev.Body = parts[1]
	default:
		ev.Title = parts[0]
		ev.Body = strings.Join(parts[1:], ";")
	}
	if strings.TrimSpace(ev.Title) == "" && strings.TrimSpace(ev.Body) == "" {
		return Event{}, false
	}
	return ev, true
}

func parseKittyParams(metadata string) map[string]string {
	out := map[string]string{}
	if metadata == "" {
		return out
	}
	for _, part := range strings.Split(metadata, ":") {
		key, val, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		out[key] = val
	}
	return out
}

func parseFileURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	if u.Scheme != "file" {
		// Some shells emit path only
		if strings.HasPrefix(raw, "/") {
			return raw
		}
		return ""
	}
	return u.Path
}
