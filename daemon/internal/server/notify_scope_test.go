package server

import (
	"io"
	"log"
	"testing"
	"time"

	"github.com/sudabon/webtabinal/internal/agentdetect"
	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/notifyarbiter"
	"github.com/sudabon/webtabinal/internal/osc"
	"github.com/sudabon/webtabinal/internal/session"
)

// agentHub builds a Hub over a live session whose detector has already
// resolved an identity from command, so notification routing can be exercised
// without driving a real PTY.
type agentHub struct {
	hub   *Hub
	conn  *wsClient
	sess  *session.Session
	store *config.Store
	clock *agentdetect.ManualClock
}

func newAgentHub(t *testing.T, command string) *agentHub {
	t.Helper()
	clock := agentdetect.NewManualClock(time.Unix(1_700_000_000, 0))
	c := &wsClient{send: make(chan []byte, 16), quit: make(chan struct{})}
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	eng := agentdetect.New(agentdetect.Options{
		Registry: agentdetect.Load(agentdetect.LoadOptions{DisableLocal: true}),
		Clock:    clock,
	})
	mgr.SetEngine(eng)
	live, err := mgr.Create("")
	if err != nil {
		t.Fatal(err)
	}
	if command != "" {
		eng.OnCommandStart(live.ID, command)
	}
	h := &Hub{
		manager:   mgr,
		cfg:       store,
		clients:   map[*wsClient]struct{}{c: {}},
		arbiter:   notifyarbiter.New(clock),
		lastAgent: map[string]agentdetect.State{},
	}
	drainClient(c)
	return &agentHub{hub: h, conn: c, sess: live, store: store, clock: clock}
}

func (a *agentHub) nextNotify(t *testing.T) map[string]any {
	t.Helper()
	return nextNotifyFrame(t, a.conn)
}

// Whether a notification raises a banner is the client's decision, driven by
// notification.commands. The daemon broadcasts every eligible event so the tab
// can be marked unread regardless.
func TestOSCNotifyIsBroadcastForUnidentifiedSession(t *testing.T) {
	a := newAgentHub(t, "")
	a.hub.broadcastNotify(a.sess, osc.Event{Kind: osc.EventNotify, Title: "make", Body: "build finished", OSC: 9})

	msg := a.nextNotify(t)
	if msg == nil {
		t.Fatal("expected a notify frame")
	}
	if _, ok := msg["banner"]; ok {
		t.Fatalf("daemon must not decide banner eligibility: %#v", msg)
	}
	if msg["body"] != "build finished" {
		t.Fatalf("notify frame = %#v", msg)
	}
}

func TestOSCNotifyIsBroadcastForIdentifiedAgent(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.hub.broadcastNotify(a.sess, osc.Event{Kind: osc.EventNotify, Title: "Codex", Body: "needs approval", OSC: 9})

	msg := a.nextNotify(t)
	if msg == nil {
		t.Fatal("expected a notify frame")
	}
	if _, ok := msg["banner"]; ok {
		t.Fatalf("daemon must not decide banner eligibility: %#v", msg)
	}
}

func TestBlockedNotifyIsBroadcastRegardlessOfAgent(t *testing.T) {
	a := newAgentHub(t, "codex")
	a.hub.lastAgent[a.sess.ID] = agentdetect.StateWorking

	a.hub.onAgentSnapshot(agentdetect.Snapshot{
		SessionID: a.sess.ID,
		AgentID:   agentdetect.IDGeneric,
		State:     agentdetect.StateBlocked,
		Since:     a.clock.Now(),
		Signal:    agentdetect.SignalScreen,
	})

	msg := a.nextNotify(t)
	if msg == nil {
		t.Fatal("expected a notify frame")
	}
	if msg["kind"] != "agent_blocked" || msg["source"] != "screen" {
		t.Fatalf("blocked frame = %#v", msg)
	}
	if _, ok := msg["banner"]; ok {
		t.Fatalf("daemon must not decide banner eligibility: %#v", msg)
	}
}
