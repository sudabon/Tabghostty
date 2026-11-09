package restore

import (
	"fmt"
	"strings"

	"github.com/sudabon/webtabinal/internal/config"
)

// builtinCommands is the resume command for each agent WebTabinal can bring
// back. An agent absent from this table is not restorable unless configuration
// supplies a command for it.
//
// The table lives here rather than in a detection manifest on purpose: manifests
// are observation-only, so a local manifest must never be able to introduce a
// command the daemon runs at startup.
var builtinCommands = map[string]string{
	"claude":       "claude --continue",
	"codex":        "codex resume --last",
	"cursor-agent": "cursor-agent resume",
}

// BuiltinCommands returns a copy of the built-in resume command table.
func BuiltinCommands() map[string]string {
	out := make(map[string]string, len(builtinCommands))
	for agent, command := range builtinCommands {
		out[agent] = command
	}
	return out
}

// Resolution is the outcome of looking up an agent's resume command. When OK is
// false, Reason says why the agent cannot be restored, so the caller can log it.
type Resolution struct {
	Command string
	OK      bool
	Reason  string
}

// ResolveCommand works out the resume command for an agent ID. A configured
// entry overrides the built-in; a configured empty string disables restore for
// that agent; an agent with neither is not restorable. The resolved command is
// then validated, because it is typed into a live shell.
func ResolveCommand(agentID string, overrides map[string]string) Resolution {
	id := strings.TrimSpace(agentID)
	if id == "" {
		return Resolution{Reason: "no detected agent"}
	}
	command, configured := overrides[id]
	if !configured {
		command, configured = builtinCommands[id]
	}
	if !configured {
		return Resolution{Reason: fmt.Sprintf("agent %q has no resume command", id)}
	}
	if strings.TrimSpace(command) == "" {
		// Distinguished from "unmapped" so the log says the user turned it off.
		return Resolution{Reason: fmt.Sprintf("resume command for agent %q is disabled", id)}
	}
	if strings.ContainsAny(command, "\r\n") {
		return Resolution{Reason: fmt.Sprintf("resume command for agent %q contains a line break", id)}
	}
	if len(command) > config.MaxResumeCommandLen {
		return Resolution{Reason: fmt.Sprintf("resume command for agent %q exceeds %d characters", id, config.MaxResumeCommandLen)}
	}
	return Resolution{Command: strings.TrimSpace(command), OK: true}
}

// Restorable reports whether an agent ID resolves to a usable resume command.
func Restorable(agentID string, overrides map[string]string) bool {
	return ResolveCommand(agentID, overrides).OK
}
