// Tabghostty: tests for binary output frames (ws_binary.go). Not part of upstream webtabinal.

package server

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sudabon/webtabinal/internal/session"
)

// goldenBinaryFrame is also decoded by Tabghostty's Tests/DaemonClientTests/BinaryFrameTests.swift,
// so the Go encoder and the Swift decoder agree byte for byte.
const goldenBinaryFrame = "032431323365343536372d653839622d313264332d613435362d3432363631343137343030301b5b33316de697a5e69cac1b5b306d0d0a"

func TestBinaryFrameMatchesGoldenVector(t *testing.T) {
	got := binaryFrame(binaryKindReplayDone, "123e4567-e89b-12d3-a456-426614174000", []byte("\x1b[31m日本\x1b[0m\r\n"))
	if hex.EncodeToString(got) != goldenBinaryFrame {
		t.Fatalf("frame = %x\nwant    %s", got, goldenBinaryFrame)
	}
}

func TestBinarySIDRules(t *testing.T) {
	for sid, want := range map[string]bool{
		"s1":                                   true,
		"123e4567-e89b-12d3-a456-426614174000": true,
		"":                                     false,
		strings.Repeat("a", 255):               true,
		strings.Repeat("a", 256):               false,
		"é":                                    false,
	} {
		if got := binarySID(sid); got != want {
			t.Errorf("binarySID(%q) = %v, want %v", sid, got, want)
		}
	}
	c := &wsClient{}
	c.setBinaryLocked("é", true)
	if c.usesBinary("é") {
		t.Fatal("a sid that cannot be encoded must fall back to JSON")
	}
}

func TestMessageTypeFollowsFirstByte(t *testing.T) {
	if wsMessageType([]byte(`{"t":"output"}`)) != websocket.TextMessage {
		t.Fatal("JSON must be a text message")
	}
	for _, kind := range []byte{binaryKindOutput, binaryKindReplay, binaryKindReplayDone} {
		if wsMessageType(binaryFrame(kind, "s", []byte("x"))) != websocket.BinaryMessage {
			t.Fatalf("kind %#x must be a binary message", kind)
		}
	}
}

func newTestClient(binary map[string]bool, attached ...string) *wsClient {
	c := &wsClient{
		attach:       map[string]bool{},
		replaying:    map[string]bool{},
		pending:      map[string][][]byte{},
		pendingBytes: map[string]int{},
		send:         make(chan []byte, 256),
		quit:         make(chan struct{}),
		binary:       binary,
	}
	for _, sid := range attached {
		c.attach[sid] = true
	}
	return c
}

func drain(c *wsClient) [][]byte {
	var out [][]byte
	for {
		select {
		case b := <-c.send:
			out = append(out, b)
		default:
			return out
		}
	}
}

func TestBroadcastOutputUsesEachClientsFormat(t *testing.T) {
	binaryClient := newTestClient(map[string]bool{"s": true}, "s")
	jsonClient := newTestClient(nil, "s")
	h := &Hub{clients: map[*wsClient]struct{}{binaryClient: {}, jsonClient: {}}}

	h.broadcastOutput(&session.Session{ID: "s"}, []byte("live\x00\xff"))

	got := drain(binaryClient)
	if len(got) != 1 || !bytes.Equal(got[0], binaryFrame(binaryKindOutput, "s", []byte("live\x00\xff"))) {
		t.Fatalf("binary client got %q", got)
	}
	frames := drain(jsonClient)
	if len(frames) != 1 {
		t.Fatalf("JSON client got %q", frames)
	}
	var msg map[string]any
	if err := json.Unmarshal(frames[0], &msg); err != nil || msg["t"] != "output" {
		t.Fatalf("JSON client frame = %s (%v)", frames[0], err)
	}
}

func TestFlushAttachPendingSendsBinaryOutput(t *testing.T) {
	c := newTestClient(map[string]bool{"s": true}, "s")
	c.replaying["s"] = true
	h := &Hub{clients: map[*wsClient]struct{}{c: {}}}

	h.broadcastOutput(&session.Session{ID: "s"}, []byte("during-attach"))
	if len(c.send) != 0 {
		t.Fatal("output was sent before the replay finished")
	}
	if h.flushAttachPending(c, "s") {
		t.Fatal("unexpected overflow")
	}
	got := drain(c)
	if len(got) != 1 || !bytes.Equal(got[0], binaryFrame(binaryKindOutput, "s", []byte("during-attach"))) {
		t.Fatalf("flushed %q", got)
	}
}

func TestReplayBinaryChunksEndWithDone(t *testing.T) {
	h := &Hub{}
	c := newTestClient(nil)
	buf := bytes.Repeat([]byte("0123456789"), 5000) // 50,000 bytes -> 3 chunks of 24 KiB
	h.sendReplayBinary(c, "s", buf, 24*1024)
	frames := drain(c)
	if len(frames) != 3 {
		t.Fatalf("frames = %d, want 3", len(frames))
	}
	var payload []byte
	for i, f := range frames {
		want := binaryKindReplay
		if i == len(frames)-1 {
			want = binaryKindReplayDone
		}
		if f[0] != want || f[1] != 1 || f[2] != 's' {
			t.Fatalf("frame %d header = %x", i, f[:3])
		}
		payload = append(payload, f[3:]...)
	}
	if !bytes.Equal(payload, buf) {
		t.Fatal("replay payload differs from the ring contents")
	}

	h.sendReplayBinary(c, "s", nil, 24*1024)
	if got := drain(c); len(got) != 1 || !bytes.Equal(got[0], []byte{binaryKindReplayDone, 1, 's'}) {
		t.Fatalf("empty replay = %x", got)
	}
}

// attach goes through handleClient with a real session: with "binary": true the replay
// arrives as binary frames, without it as JSON, and the state frame stays JSON either way.
func TestAttachReplaysInTheDeclaredFormat(t *testing.T) {
	store := testConfigStore(t)
	mgr := session.NewManager(store, log.New(io.Discard, "", 0))
	t.Cleanup(mgr.Close)
	h := NewHub(mgr, store, log.New(io.Discard, "", 0))
	sess, err := mgr.Create(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sess.Ring.Write([]byte("RING-MARKER"))

	for _, binary := range []bool{true, false} {
		c := newTestClient(nil)
		h.handleClient(c, clientMsg{T: "attach", SID: sess.ID, Binary: binary})
		frames := drain(c)
		if len(frames) < 2 {
			t.Fatalf("binary=%v: frames = %q", binary, frames)
		}
		var replay []byte
		sawDone := false
		for _, f := range frames {
			if wsMessageType(f) == websocket.BinaryMessage {
				if !binary {
					t.Fatalf("binary frame sent without the declaration: %x", f[:2])
				}
				if f[0] == binaryKindOutput || int(f[1]) != len(sess.ID) || string(f[2:2+len(sess.ID)]) != sess.ID {
					t.Fatalf("unexpected binary frame header %x", f[:2+len(sess.ID)])
				}
				replay = append(replay, f[2+len(sess.ID):]...)
				sawDone = sawDone || f[0] == binaryKindReplayDone
				continue
			}
			var msg map[string]any
			if err := json.Unmarshal(f, &msg); err != nil {
				t.Fatalf("text frame is not JSON: %q", f)
			}
			if msg["t"] == "replay" {
				if binary {
					t.Fatal("JSON replay sent despite the binary declaration")
				}
				replay = append(replay, []byte(msg["data"].(string))...)
				sawDone = sawDone || msg["done"] == true
			}
		}
		if !sawDone {
			t.Fatalf("binary=%v: replay never completed", binary)
		}
		if binary && !bytes.Contains(replay, []byte("RING-MARKER")) {
			t.Fatalf("binary replay = %q, want the ring contents", replay)
		}
		if !binary && len(replay) == 0 {
			t.Fatal("JSON replay carried no data")
		}
	}
}

func TestWriteClientSendsBinaryAndTextMessages(t *testing.T) {
	serverConn := make(chan *websocket.Conn, 1)
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		serverConn <- conn
	}))
	defer httpServer.Close()
	clientConn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(httpServer.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()
	c := newTestClient(nil)
	c.conn = <-serverConn
	h := &Hub{clients: map[*wsClient]struct{}{}}
	go h.writeClient(c)
	defer h.disconnect(c)

	h.sendBytes(c, binaryFrame(binaryKindOutput, "s", []byte("raw")))
	h.send(c, map[string]any{"t": "state", "sid": "s"})

	_ = clientConn.SetReadDeadline(time.Now().Add(5 * time.Second))
	mt, data, err := clientConn.ReadMessage()
	if err != nil || mt != websocket.BinaryMessage || !bytes.Equal(data, binaryFrame(binaryKindOutput, "s", []byte("raw"))) {
		t.Fatalf("first message = %d %x %v", mt, data, err)
	}
	mt, data, err = clientConn.ReadMessage()
	if err != nil || mt != websocket.TextMessage || !strings.Contains(string(data), `"state"`) {
		t.Fatalf("second message = %d %s %v", mt, data, err)
	}
}
