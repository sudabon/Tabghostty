// Tabghostty: binary output frames (openspec/changes/phase6-daemon-ghostty-screen design D3,
// spec bundled-daemon "Binary output frames format"). Not part of upstream webtabinal;
// see daemon/UPSTREAM.md for the matching changes in ws.go.
//
// A client that attaches a session with {"t":"attach","sid":…,"binary":true} receives that
// session's replay and output as binary WebSocket messages:
//
//	byte 0      kind: 0x01 output, 0x02 replay chunk (more follow), 0x03 final replay chunk
//	byte 1      sid length N (1–255)
//	byte 2..2+N sid (ASCII)
//	rest        raw PTY bytes
//
// Every other frame stays JSON. Binary frames share the client's send queue with JSON
// frames; writeClient tells them apart by the first byte, because json.Marshal output
// never starts with a byte in 0x01–0x03.

package server

import (
	"github.com/gorilla/websocket"
)

const (
	binaryKindOutput     byte = 0x01
	binaryKindReplay     byte = 0x02
	binaryKindReplayDone byte = 0x03
)

// binarySID reports whether sid fits the binary frame header (ASCII, 1–255 bytes).
func binarySID(sid string) bool {
	if len(sid) == 0 || len(sid) > 0xFF {
		return false
	}
	for i := 0; i < len(sid); i++ {
		if sid[i] >= 0x80 {
			return false
		}
	}
	return true
}

// binaryFrame encodes one binary message. sid must satisfy binarySID.
func binaryFrame(kind byte, sid string, data []byte) []byte {
	b := make([]byte, 0, 2+len(sid)+len(data))
	b = append(b, kind, byte(len(sid)))
	b = append(b, sid...)
	return append(b, data...)
}

// wsMessageType picks the WebSocket message type for a queued frame.
func wsMessageType(b []byte) int {
	if len(b) > 0 && b[0] >= binaryKindOutput && b[0] <= binaryKindReplayDone {
		return websocket.BinaryMessage
	}
	return websocket.TextMessage
}

// setBinaryLocked records whether the latest attach of sid on this connection asked for
// binary frames. c.mu must be held.
func (c *wsClient) setBinaryLocked(sid string, binary bool) {
	if c.binary == nil {
		c.binary = map[string]bool{}
	}
	c.binary[sid] = binary && binarySID(sid)
}

// usesBinary reports whether sid's replay and output go to this client as binary frames.
func (c *wsClient) usesBinary(sid string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.binary[sid]
}

// sendReplayBinary sends the ring contents as 0x02 chunks ending with a 0x03 chunk.
// An empty ring is a single empty 0x03 message.
func (h *Hub) sendReplayBinary(c *wsClient, sid string, buf []byte, chunk int) {
	if len(buf) == 0 {
		h.sendBytes(c, binaryFrame(binaryKindReplayDone, sid, nil))
		return
	}
	for i := 0; i < len(buf); i += chunk {
		end := i + chunk
		if end > len(buf) {
			end = len(buf)
		}
		kind := binaryKindReplay
		if end >= len(buf) {
			kind = binaryKindReplayDone
		}
		h.sendBytes(c, binaryFrame(kind, sid, buf[i:end]))
	}
}

// sendOutputBinary sends live output as a 0x01 message.
func (h *Hub) sendOutputBinary(c *wsClient, sid string, data []byte) {
	h.sendBytes(c, binaryFrame(binaryKindOutput, sid, data))
}
