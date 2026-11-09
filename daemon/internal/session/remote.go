package session

import (
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

// Remote-shell state approximation.
//
// A session that has logged into another host reports `running` for the whole
// login. Both existing detectors are blind to the far side: the local shell
// integration emits command-start when `ssh` launches and then stays silent
// until it returns, and the fallback poller only ever sees `ssh` holding the
// foreground. The remote shell has none of our integration to emit OSC from,
// so nothing tells either detector that the remote prompt came back.
//
// While a login client owns the foreground we therefore read idle vs running
// off the screen instead. The rules below are intentionally few, and every
// screen they cannot classify resolves to `running` — the behaviour that was
// already there — so an unrecognised remote prompt costs accuracy rather than
// correctness.

// remoteClientNames are foreground executables that hand the terminal to a
// shell on another host. The list stays limited to interactive login clients:
// `scp` and `rsync` never present a remote prompt, and `docker` / `kubectl`
// cannot be told apart from local work by executable name alone.
var remoteClientNames = map[string]bool{
	"ssh":         true,
	"slogin":      true,
	"autossh":     true,
	"mosh":        true,
	"mosh-client": true,
}

// isRemoteClient reports whether a foreground process name is a login client.
// The name comes from `ps -o comm=`, which yields a bare command on Linux and
// may yield a full path on macOS.
func isRemoteClient(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" {
		return false
	}
	return remoteClientNames[filepath.Base(name)]
}

// promptSuffixes are the characters an interactive shell prompt conventionally
// ends with. This is what separates a quiet prompt from a quiet command: a
// command line echoed by the remote shell keeps the command's own last
// character, so `sleep 60` does not read as a prompt even though its screen is
// every bit as static as an idle one.
const promptSuffixes = "$#%>❯➜»›"

// looksLikePrompt reports whether a line ends the way a shell prompt does,
// ignoring the trailing blanks a terminal pads the row with.
func looksLikePrompt(line string) bool {
	line = strings.TrimRight(line, " \t")
	if line == "" {
		return false
	}
	last, _ := utf8.DecodeLastRuneInString(line)
	return strings.ContainsRune(promptSuffixes, last)
}

// remoteRunning classifies a session whose foreground is a login client.
// An unreadable screen keeps the session `running`, matching what the
// foreground process alone would have reported.
func remoteRunning(snap vtscreen.Snapshot) bool {
	if !snap.Available {
		return true
	}
	// A full-screen program on the far side — vim, top, less — is a command in
	// flight, and its screen has no shell prompt to find.
	if snap.Active == vtscreen.BufferAlternate {
		return true
	}
	return !looksLikePrompt(lastNonBlankLine(snap.Lines))
}

// lastNonBlankLine returns the bottom-most line carrying visible text, which
// is where a shell leaves its prompt.
func lastNonBlankLine(lines []string) string {
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.TrimSpace(lines[i]) != "" {
			return lines[i]
		}
	}
	return ""
}
