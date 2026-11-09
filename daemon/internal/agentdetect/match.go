package agentdetect

// PatternHit identifies a manifest pattern that matched a visible line.
// It never includes the matched substring.
type PatternHit struct {
	ID    string
	Line  int
	State State
}

// MatchManifest reports every state pattern that matches the given lines.
func MatchManifest(man *CompiledManifest, lines []string) []PatternHit {
	if man == nil {
		return nil
	}
	var out []PatternHit
	out = append(out, matchState(StateBlocked, man.Blocked, lines)...)
	out = append(out, matchState(StateWorking, man.Working, lines)...)
	out = append(out, matchState(StateIdle, man.Idle, lines)...)
	return out
}

func matchState(state State, patterns []CompiledPattern, lines []string) []PatternHit {
	var out []PatternHit
	for _, p := range patterns {
		for i, line := range lines {
			if p.RE.MatchString(line) {
				out = append(out, PatternHit{ID: p.ID, Line: i, State: state})
				break
			}
		}
	}
	return out
}
