package agentdetect

import (
	"testing"
	"time"
)

func codexBlockedPatternIDs(t *testing.T, lines ...string) []string {
	t.Helper()
	reg := Load(LoadOptions{DisableLocal: true})
	m, ok := reg.Manifest(IDCodex)
	if !ok {
		t.Fatal("missing codex manifest")
	}
	var ids []string
	for _, hit := range MatchManifest(m, lines) {
		if hit.State == StateBlocked {
			ids = append(ids, hit.ID)
		}
	}
	return ids
}

func hasID(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}

// codex-cli 0.149.0 replaced "Allow this command to run in your workspace?" with
// "Would you like to run the following command?".
func TestCodexExecApprovalHeaderBlocks(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set(
		"Would you like to run the following command?",
		"",
		"Environment: local",
		"",
		"Reason: May I run the focused Go test packages?",
		"",
		"$ gofmt -w internal/profile/*.go && go test ./internal/profile",
		"",
		"  1. Yes, proceed (y)",
		"› 2. Yes, and don't ask again for commands that start with `gofmt -w` (p)",
		"  3. No, and tell Codex what to do differently (esc)",
	)
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateBlocked {
		t.Fatalf("state = %s, want blocked", s.State)
	}
	if s.Signal != SignalScreen {
		t.Fatalf("signal = %s, want screen", s.Signal)
	}
}

func TestCodexApprovalHeadersMatchShippedWording(t *testing.T) {
	for _, header := range []string{
		"Would you like to run the following command?",
		"Would you like to make the following edits?",
		"Would you like to grant these permissions?",
	} {
		ids := codexBlockedPatternIDs(t, header)
		if !hasID(ids, "approval-would") {
			t.Errorf("%q matched %v, want approval-would", header, ids)
		}
	}
}

// A long command wraps the option list far enough that the header scrolls out of
// the bottom 15 lines. The numbered option list has to carry the detection alone.
func TestCodexApprovalDetectedWithoutHeader(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set(
		"     ./internal/casereg ./internal/users ./internal/projectmember ./internal/httpapi` (p)",
		"  3. No, and tell Codex what to do differently (esc)",
	)
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateBlocked {
		t.Fatalf("state = %s, want blocked from the option list alone", s.State)
	}
	ids := codexBlockedPatternIDs(t, "  3. No, and tell Codex what to do differently (esc)")
	if !hasID(ids, "approval-choice") {
		t.Fatalf("option line matched %v, want approval-choice", ids)
	}
}

func TestCodexApprovalChoiceMatchesSelectedAndUnselectedRows(t *testing.T) {
	for _, line := range []string{
		"  1. Yes, proceed (y)",
		"› 2. Yes, and don't ask again for these files (p)",
		"› 1. Yes, just this once (y)",
		"  2. No, continue without running it",
		"  3. No, and tell Codex what to do differently (esc)",
	} {
		if ids := codexBlockedPatternIDs(t, line); !hasID(ids, "approval-choice") {
			t.Errorf("%q matched %v, want approval-choice", line, ids)
		}
	}
}

func TestCodexApprovalPatternsIgnoreNonApprovalScreens(t *testing.T) {
	cases := map[string][]string{
		"agent prose": {
			"I updated the profile handler and reran the focused tests.",
			"Would you like me to run the full suite next?",
			"›",
		},
		"model picker": {
			"Select a model",
			"› 1. gpt-5.1-codex",
			"  2. gpt-5.1-codex-mini",
		},
		"numbered plan": {
			"Plan:",
			"  1. Extract the profile service",
			"  2. Wire the HTTP route",
			"›",
		},
		"working": {
			"Thinking...",
			"esc to interrupt",
		},
	}
	for name, lines := range cases {
		if ids := codexBlockedPatternIDs(t, lines...); len(ids) != 0 {
			t.Errorf("%s: blocked patterns %v matched a non-approval screen", name, ids)
		}
	}
}

// The Codex status line ("Working (19m 17s • esc to interrupt)") is only shown
// while no approval modal is open. Approval-like prose or numbered Yes/No lists
// left in the transcript above it must not report blocked.
func TestCodexWorkingStatusLineSuppressesStaleBlockedText(t *testing.T) {
	for name, lines := range map[string][]string{
		"approval-like prose": {
			"• Do you want to keep the legacy handler? I'll assume yes for now.",
			"",
			"• Working (19m 17s • esc to interrupt)",
			"",
			"›",
		},
		"numbered yes/no list in transcript": {
			"  1. Yes, migrate the handler",
			"  2. No, keep both",
			"",
			"◦ Working (3m 02s • esc to interrupt)",
		},
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t, nil)
			identifyCodex(h)
			h.screen.set(lines...)
			h.engine.OnOutput(h.id, 40)
			flushDebounce(h)
			s := mustSnap(t, h.engine, h.id)
			if s.State != StateWorking {
				t.Fatalf("state = %s (%s), want working", s.State, s.Detail)
			}
		})
	}
}

// A stale status line above a live approval modal must not hide the approval.
func TestCodexStaleStatusLineAboveApprovalStillBlocks(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set(
		"• Working (0m 12s • esc to interrupt)",
		"Would you like to run the following command?",
		"$ go test ./...",
		"› 1. Yes, proceed (y)",
		"  3. No, and tell Codex what to do differently (esc)",
	)
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	s := mustSnap(t, h.engine, h.id)
	if s.State != StateBlocked {
		t.Fatalf("state = %s, want blocked", s.State)
	}
}

// Codex redraws its status line (shimmer, elapsed timer) faster than the
// debounce interval. A trailing-edge-only debounce would never fire, freezing
// the detector on the approval screen it last captured.
func TestContinuousOutputStillRefreshesScreen(t *testing.T) {
	h := newHarness(t, nil)
	identifyCodex(h)
	h.screen.set(
		"Would you like to run the following command?",
		"$ go test ./...",
		"› 1. Yes, proceed (y)",
		"  3. No, and tell Codex what to do differently (esc)",
	)
	h.engine.OnOutput(h.id, 40)
	flushDebounce(h)
	if s := mustSnap(t, h.engine, h.id); s.State != StateBlocked {
		t.Fatalf("precondition: state = %s, want blocked", s.State)
	}

	h.screen.set(
		"• Ran go test ./...",
		"",
		"◦ Working (0m 03s • esc to interrupt)",
		"",
		"› Ask Codex to do anything",
	)
	step := DefaultDebounce / 3
	for elapsed := time.Duration(0); elapsed < 3*time.Second; elapsed += step {
		h.engine.OnOutput(h.id, 64)
		h.clock.Advance(step)
	}
	if s := mustSnap(t, h.engine, h.id); s.State != StateWorking {
		t.Fatalf("state = %s (%s), want working after the approval closed", s.State, s.Detail)
	}
}
