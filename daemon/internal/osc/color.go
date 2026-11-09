package osc

import (
	"fmt"
	"strings"
)

// Palette is the default xterm special colors (OSC 10/11/12).
// Keep hex values in sync with web/src/theme.ts terminalTheme.
type Palette struct {
	Name       string
	Foreground string
	Background string
	Cursor     string
}

func LightPalette() Palette {
	return Palette{Name: "light", Foreground: "#333333", Background: "#ffffff", Cursor: "#000000"}
}

func DarkPalette() Palette {
	return Palette{Name: "dark", Foreground: "#cccccc", Background: "#1e1e1e", Cursor: "#ffffff"}
}

func PaletteFor(theme string) Palette {
	if theme == "light" {
		return LightPalette()
	}
	return DarkPalette()
}

func (p Palette) Report(code int) []byte {
	var hex string
	switch code {
	case 10:
		hex = p.Foreground
	case 11:
		hex = p.Background
	case 12:
		hex = p.Cursor
	default:
		return nil
	}
	if hex == "" {
		return nil
	}
	return []byte(fmt.Sprintf("\x1b]%d;rgb:%s\x07", code, xparseRGB(hex)))
}

func (p Palette) Reports(ids []int) []byte {
	var out []byte
	for _, id := range ids {
		out = append(out, p.Report(id)...)
	}
	return out
}

func (p Palette) Env() []string {
	if p.Name == "light" {
		return []string{"TERM_THEME=light", "ANSI_LIGHT=1", "COLORFGBG=0;15"}
	}
	return []string{"TERM_THEME=dark", "COLORFGBG=15;0"}
}

func xparseRGB(hex string) string {
	hex = strings.TrimPrefix(hex, "#")
	if len(hex) != 6 {
		return "0000/0000/0000"
	}
	r, g, b := hex[0:2], hex[2:4], hex[4:6]
	return r + r + "/" + g + g + "/" + b + b
}

// FilterColorReports removes OSC 10/11/12 color reports unless allow returns true
// for that color code. Other bytes, including unrelated OSC sequences, are kept.
func FilterColorReports(data []byte, allow func(code int) bool) []byte {
	if len(data) == 0 {
		return data
	}
	if allow == nil {
		allow = func(int) bool { return false }
	}
	var out []byte
	i := 0
	for i < len(data) {
		start := -1
		for j := i; j+1 < len(data); j++ {
			if data[j] == 0x1b && data[j+1] == ']' {
				start = j
				break
			}
		}
		if start < 0 {
			out = append(out, data[i:]...)
			break
		}
		out = append(out, data[i:start]...)
		end := -1
		term := 0
		for j := start + 2; j < len(data); j++ {
			if data[j] == 0x07 {
				end, term = j, 1
				break
			}
			if data[j] == 0x1b && j+1 < len(data) && data[j+1] == '\\' {
				end, term = j, 2
				break
			}
		}
		if end < 0 {
			payload := string(data[start+2:])
			if _, ok := colorReportCode(payload); ok {
				break
			}
			out = append(out, data[start:]...)
			break
		}
		payload := string(data[start+2 : end])
		if code, ok := colorReportCode(payload); ok {
			if allow(code) {
				out = append(out, data[start:end+term]...)
			}
			i = end + term
			continue
		}
		out = append(out, data[start:end+term]...)
		i = end + term
	}
	if out == nil {
		return []byte{}
	}
	return out
}

func parseColorQueries(payload string) ([]int, bool) {
	code, rest, ok := specialColorPayload(payload)
	if !ok {
		return nil, false
	}
	var ids []int
	for i, slot := range strings.Split(rest, ";") {
		if slot != "?" {
			continue
		}
		id := code + i
		if id > 12 {
			break
		}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, false
	}
	return ids, true
}

func colorReportCode(payload string) (int, bool) {
	code, rest, ok := specialColorPayload(payload)
	if !ok || rest == "" || rest == "?" || strings.HasPrefix(rest, "?") {
		return 0, false
	}
	slot, _, _ := strings.Cut(rest, ";")
	if strings.HasPrefix(slot, "rgb:") || strings.HasPrefix(slot, "#") {
		return code, true
	}
	return 0, false
}

func specialColorPayload(payload string) (code int, rest string, ok bool) {
	switch {
	case strings.HasPrefix(payload, "10;"):
		return 10, payload[3:], true
	case strings.HasPrefix(payload, "11;"):
		return 11, payload[3:], true
	case strings.HasPrefix(payload, "12;"):
		return 12, payload[3:], true
	default:
		return 0, "", false
	}
}
