package agentdetect

import "testing"

func TestCursorCommandIdentifiesAgent(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "agent")
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDCursor {
		t.Fatalf("agent = %q, want cursor-agent", s.AgentID)
	}
}

func TestCursorExecutableIdentifiesAgent(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Executable: "cursor-agent"})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDCursor {
		t.Fatalf("agent = %q, want cursor-agent", s.AgentID)
	}
}

func TestIntegratedCommandIdentifiesAgent(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "codex --yolo")
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDCodex {
		t.Fatalf("agent = %q, want codex", s.AgentID)
	}
	if s.State == StateNone {
		t.Fatal("identified agent must not stay none")
	}
}

func TestForegroundIdentifiesUnintegratedAgent(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Executable: "claude"})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDClaude {
		t.Fatalf("agent = %q, want claude", s.AgentID)
	}
}

func TestWrapperResolvedThroughAncestry(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{
		Executable: "script",
		Ancestry:   []string{"claude"},
	})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDClaude {
		t.Fatalf("agent = %q, want claude via ancestry", s.AgentID)
	}
}

func TestUnrecognizedAltScreenUsesGeneric(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{
		Executable: "vim",
		UsingAlt:   true,
		IsShell:    false,
	})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDGeneric {
		t.Fatalf("agent = %q, want generic", s.AgentID)
	}
}

func TestOrdinaryShellHasEmptyIdentity(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Executable: "zsh", IsShell: true})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != "" || s.State != StateNone {
		t.Fatalf("got %+v, want empty/none", s)
	}
}

func TestPromptClearsIdentityWhenAgentGone(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "codex")
	h.insp.set(ForegroundInfo{IsShell: true, Executable: "zsh"})
	h.engine.OnPrompt(h.id)
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != "" || s.State != StateNone {
		t.Fatalf("got %+v, want cleared", s)
	}
}

func TestInspectorFailureDoesNotFailOrClearCommandIdentity(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "claude")
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Failed: true})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDClaude {
		t.Fatalf("agent = %q, want claude kept on inspect failure", s.AgentID)
	}
}

func TestExecutableBeatsCommandPattern(t *testing.T) {
	h := newHarness(t, nil)
	h.engine.OnCommandStart(h.id, "codex && claude")
	h.engine.OnForegroundInfo(h.id, ForegroundInfo{Executable: "claude"})
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != IDClaude {
		t.Fatalf("agent = %q, want claude exact executable", s.AgentID)
	}
}

func TestAmbiguousCommandPatternsUseStableID(t *testing.T) {
	reg := Load(LoadOptions{
		DisableLocal: true,
		Bundled: mapFS(map[string][]byte{
			"a.json": validJSON("zeta", map[string]any{
				"match": map[string]any{"executables": []string{"zeta"}, "command_patterns": []string{"agent"}},
			}),
			"b.json": validJSON("alpha", map[string]any{
				"match": map[string]any{"executables": []string{"alpha"}, "command_patterns": []string{"agent"}},
			}),
			"g.json": validJSON("generic", nil),
		}),
	})
	h := newHarness(t, reg)
	h.engine.OnCommandStart(h.id, "agent run")
	s := mustSnap(t, h.engine, h.id)
	if s.AgentID != "alpha" {
		t.Fatalf("agent = %q, want alpha (stable id)", s.AgentID)
	}
}
