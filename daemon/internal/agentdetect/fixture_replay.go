package agentdetect

import (
	"fmt"
	"strings"
	"time"

	"github.com/sudabon/webtabinal/internal/agentfixtures"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

type fixtureReplayResult struct {
	AgentID     string
	State       State
	Signal      Signal
	ChangeCount int
	Lines       []string
}

type fixtureReplayError struct {
	Dir  string
	Step string
	Want string
	Got  string
}

func (e *fixtureReplayError) Error() string {
	return fmt.Sprintf("%s step %s: got %s, want %s", e.Dir, e.Step, e.Got, e.Want)
}

func replayFixture(fx agentfixtures.Fixture, reg *Registry) ([]fixtureReplayResult, error) {
	if reg == nil {
		reg = Load(LoadOptions{DisableLocal: true})
	}
	screen, err := vtscreen.Open(vtscreen.Options{Cols: fx.Meta.Columns, Rows: fx.Meta.Rows, Name: fx.Scenario})
	if err != nil {
		return nil, fmt.Errorf("%s: vt open: %w", fx.Dir, err)
	}
	defer screen.Close()

	clock := NewManualClock(time.Unix(1_700_000_000, 0))
	engine := New(Options{Registry: reg, Clock: clock, Scheduler: clock})
	const sessionID = "fixture-replay"
	engine.Open(sessionID, screen, nil)
	defer engine.Close(sessionID)

	changes := 0
	engine.Subscribe(func(Snapshot) { changes++ })

	if cmd := strings.TrimSpace(fx.Case.Identity.Command); cmd != "" {
		engine.OnCommandStart(sessionID, cmd)
	}
	if exe := strings.TrimSpace(fx.Case.Identity.Executable); exe != "" {
		engine.OnForegroundInfo(sessionID, ForegroundInfo{Executable: exe, IsShell: false})
	}

	out := make([]fixtureReplayResult, 0, len(fx.Case.Steps))
	for _, step := range fx.Case.Steps {
		chunk := fx.Stream[step.ByteStart:step.ByteEnd]
		if err := screen.Feed(chunk); err != nil {
			return out, fmt.Errorf("%s step %s: feed: %w", fx.Dir, step.Name, err)
		}
		engine.OnOutput(sessionID, step.ActivityBytes())
		if step.AdvanceMS > 0 {
			clock.Advance(time.Duration(step.AdvanceMS) * time.Millisecond)
		} else {
			clock.Advance(0)
		}
		snap, ok := engine.Snapshot(sessionID)
		if !ok {
			return out, fmt.Errorf("%s step %s: missing snapshot", fx.Dir, step.Name)
		}
		view := screen.Snapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: fx.Meta.Rows})
		got := fixtureReplayResult{
			AgentID:     snap.AgentID,
			State:       snap.State,
			Signal:      snap.Signal,
			ChangeCount: changes,
			Lines:       append([]string(nil), view.Lines...),
		}
		if err := compareFixtureStep(fx.Dir, step, got); err != nil {
			return out, err
		}
		out = append(out, got)
	}
	return out, nil
}

func compareFixtureStep(dir string, step agentfixtures.Step, got fixtureReplayResult) error {
	fail := func(want, actual string) error {
		return &fixtureReplayError{Dir: dir, Step: step.Name, Want: want, Got: actual}
	}
	if got.AgentID != step.Expect.AgentID {
		return fail("agent_id="+step.Expect.AgentID, "agent_id="+got.AgentID)
	}
	if string(got.State) != step.Expect.State {
		return fail("state="+step.Expect.State, "state="+string(got.State))
	}
	if string(got.Signal) != step.Expect.Signal {
		return fail("signal="+step.Expect.Signal, "signal="+string(got.Signal))
	}
	if step.Expect.ChangeCount != nil && got.ChangeCount != *step.Expect.ChangeCount {
		return fail(fmt.Sprintf("change_count=%d", *step.Expect.ChangeCount), fmt.Sprintf("change_count=%d", got.ChangeCount))
	}
	if len(step.BottomLines) > 0 {
		if err := compareBottomLines(step.BottomLines, got.Lines); err != nil {
			return fail("bottom_lines match", err.Error())
		}
	}
	return nil
}

func compareBottomLines(want, got []string) error {
	if len(got) < len(want) {
		return fmt.Errorf("screen has %d lines, want last %d", len(got), len(want))
	}
	suffix := got[len(got)-len(want):]
	for i := range want {
		if strings.TrimRight(suffix[i], " ") != strings.TrimRight(want[i], " ") {
			return fmt.Errorf("line %d mismatch", i)
		}
	}
	return nil
}
