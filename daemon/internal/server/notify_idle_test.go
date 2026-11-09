package server

import (
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/notifyarbiter"
	"github.com/sudabon/webtabinal/internal/osc"
)

// enableIdleNotify opts into the screen-derived prompt-return notification,
// which now ships off.
func (a *agentHub) enableIdleNotify(t *testing.T) {
	t.Helper()
	if _, err := a.store.Patch(map[string]any{"state": map[string]any{"notify_on_idle": true}}); err != nil {
		t.Fatal(err)
	}
}

func (a *agentHub) transition(from, to agentdetect.State) {
	a.hub.mu.Lock()
	a.hub.lastAgent[a.sess.ID] = from
	a.hub.mu.Unlock()
	a.hub.onAgentSnapshot(agentdetect.Snapshot{
		SessionID: a.sess.ID,
		AgentID:   agentdetect.IDCodex,
		State:     to,
		Since:     a.clock.Now(),
		Signal:    agentdetect.SignalScreen,
	})
}

func TestWorkingToIdleNotifiesPromptReturn(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.enableIdleNotify(t)
	a.transition(agentdetect.StateWorking, agentdetect.StateIdle)

	msg := a.nextNotify(t)
	if msg == nil {
		t.Fatal("expected a prompt-return notify frame")
	}
	if msg["kind"] != "agent_idle" || msg["source"] != "screen" {
		t.Fatalf("prompt-return frame = %#v", msg)
	}
	if msg["title"] != "Codex" {
		t.Fatalf("title = %v, want the agent display name", msg["title"])
	}
	if msg["body"] == "" || msg["body"] == nil {
		t.Fatalf("body = %v, want a ready-for-input message", msg["body"])
	}
	if _, ok := msg["banner"]; ok {
		t.Fatalf("daemon must not decide banner eligibility: %#v", msg)
	}
	if extra := a.nextNotify(t); extra != nil {
		t.Fatalf("expected exactly one notify, got another: %#v", extra)
	}
}

func TestIdleFromNoneDoesNotNotify(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.transition(agentdetect.StateNone, agentdetect.StateIdle)

	if msg := a.nextNotify(t); msg != nil {
		t.Fatalf("session start should not notify: %#v", msg)
	}
}

func TestIdleFromBlockedDoesNotNotify(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.transition(agentdetect.StateBlocked, agentdetect.StateIdle)

	if msg := a.nextNotify(t); msg != nil {
		t.Fatalf("answering an approval should not notify: %#v", msg)
	}
}

func TestRepeatedIdleDoesNotNotifyAgain(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.enableIdleNotify(t)
	a.transition(agentdetect.StateWorking, agentdetect.StateIdle)
	if msg := a.nextNotify(t); msg == nil {
		t.Fatal("expected the first prompt-return notify")
	}
	a.clock.Advance(notifyarbiter.Window)

	a.hub.onAgentSnapshot(agentdetect.Snapshot{
		SessionID: a.sess.ID,
		AgentID:   agentdetect.IDCodex,
		State:     agentdetect.StateIdle,
		Since:     a.clock.Now(),
		Signal:    agentdetect.SignalScreen,
	})
	if msg := a.nextNotify(t); msg != nil {
		t.Fatalf("repeated idle evidence notified again: %#v", msg)
	}
}

func TestPromptReturnDedupesWithOSC(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.enableIdleNotify(t)
	a.hub.broadcastNotify(a.sess, osc.Event{Kind: osc.EventNotify, Title: "Codex", Body: "turn complete", OSC: 9})
	if msg := a.nextNotify(t); msg == nil {
		t.Fatal("expected the OSC notify")
	}

	a.clock.Advance(time.Second)
	a.transition(agentdetect.StateWorking, agentdetect.StateIdle)
	if msg := a.nextNotify(t); msg != nil {
		t.Fatalf("prompt return within the window should be deduped: %#v", msg)
	}

	a.clock.Advance(notifyarbiter.Window)
	a.transition(agentdetect.StateWorking, agentdetect.StateIdle)
	if msg := a.nextNotify(t); msg == nil {
		t.Fatal("a prompt return after the window should notify")
	}
}

func TestPromptReturnSkippedWhenDetectionDisabled(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.enableIdleNotify(t)
	if _, err := a.store.Patch(map[string]any{"state": map[string]any{"enabled": false}}); err != nil {
		t.Fatal(err)
	}
	a.transition(agentdetect.StateWorking, agentdetect.StateIdle)

	if msg := a.nextNotify(t); msg != nil {
		t.Fatalf("disabled detection should not produce prompt-return notifications: %#v", msg)
	}
}

// The change that introduced state.notify_on_idle flipped this behavior off by
// default, so a stock configuration must stay quiet on prompt return.
func TestPromptReturnIsOffByDefault(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.transition(agentdetect.StateWorking, agentdetect.StateIdle)

	if msg := a.nextNotify(t); msg != nil {
		t.Fatalf("screen-derived prompt return notified without notify_on_idle: %#v", msg)
	}
}

// Turning the screen-derived notification off must not silence the approval
// prompt, which detection reports reliably.
func TestBlockedStillNotifiesWithIdleNotifyOff(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.transition(agentdetect.StateWorking, agentdetect.StateBlocked)

	msg := a.nextNotify(t)
	if msg == nil {
		t.Fatal("expected a blocked notify frame")
	}
	if msg["kind"] != notifyKindAgentBlocked {
		t.Fatalf("kind = %#v", msg["kind"])
	}
}
