package session

import (
	"testing"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

func TestIsRemoteClient(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"ssh", true},
		{"/usr/bin/ssh", true},
		{"mosh-client", true},
		{"autossh", true},
		{" ssh ", true},
		{"", false},
		{"sshd", false},
		{"scp", false},
		{"rsync", false},
		{"zsh", false},
		{"claude", false},
	}
	for _, tc := range cases {
		if got := isRemoteClient(tc.name); got != tc.want {
			t.Errorf("isRemoteClient(%q) = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestLooksLikePrompt(t *testing.T) {
	cases := []struct {
		line string
		want bool
	}{
		{"[user@host ~]$ ", true},
		{"user@host:~$", true},
		{"user@host:/etc# ", true},
		{"host%", true},
		{"~ ❯ ", true},
		{">>> ", true},
		// An echoed command keeps its own last character, which is what makes
		// a quiet command distinguishable from a quiet prompt.
		{"[user@host ~]$ sleep 60", false},
		{"user@host:~$ tail -f /var/log/messages", false},
		{"[sudo] password for user: ", false},
		{"", false},
		{"   ", false},
		{"total 48", false},
	}
	for _, tc := range cases {
		if got := looksLikePrompt(tc.line); got != tc.want {
			t.Errorf("looksLikePrompt(%q) = %v, want %v", tc.line, got, tc.want)
		}
	}
}

func TestRemoteRunning(t *testing.T) {
	cases := []struct {
		name string
		snap vtscreen.Snapshot
		want bool
	}{
		{
			name: "unreadable screen stays running",
			snap: vtscreen.Snapshot{Available: false},
			want: true,
		},
		{
			name: "remote prompt is idle",
			snap: vtscreen.Snapshot{
				Available: true,
				Active:    vtscreen.BufferPrimary,
				Lines:     []string{"Last login: Tue Sep  9 10:00:00 2026", "[user@remote ~]$ ", "", ""},
			},
			want: false,
		},
		{
			name: "echoed command is running",
			snap: vtscreen.Snapshot{
				Available: true,
				Active:    vtscreen.BufferPrimary,
				Lines:     []string{"[user@remote ~]$ sleep 60", "", ""},
			},
			want: true,
		},
		{
			name: "streaming output is running",
			snap: vtscreen.Snapshot{
				Available: true,
				Active:    vtscreen.BufferPrimary,
				Lines:     []string{"[user@remote ~]$ make", "gcc -c main.c", "gcc -c util.c"},
			},
			want: true,
		},
		{
			name: "alternate screen is running",
			snap: vtscreen.Snapshot{
				Available: true,
				Active:    vtscreen.BufferAlternate,
				// top(1) draws a prompt-looking line, so only the buffer kind
				// keeps this out of idle.
				Lines: []string{"top - 10:00:00 up 1 day", "Tasks: 120 total%"},
			},
			want: true,
		},
		{
			name: "blank screen is running",
			snap: vtscreen.Snapshot{
				Available: true,
				Active:    vtscreen.BufferPrimary,
				Lines:     []string{"", "", ""},
			},
			want: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := remoteRunning(tc.snap); got != tc.want {
				t.Errorf("remoteRunning() = %v, want %v", got, tc.want)
			}
		})
	}
}

// An integrated session is the case that regressed: `ssh` set it running via
// OSC and nothing on the far side can clear it, so SetRemoteState must be
// allowed to override where SetFallbackState bails out.
func TestSetRemoteStateOverridesIntegratedRunning(t *testing.T) {
	s := &Session{State: StateRunning, Integrated: true, Command: "ssh remote"}

	s.SetFallbackState(false, "ssh")
	if s.Info().State != StateRunning {
		t.Fatalf("SetFallbackState changed an integrated session: %s", s.Info().State)
	}

	s.SetRemoteState(false, "ssh")
	info := s.Info()
	if info.State != StateIdle {
		t.Errorf("state = %s, want idle", info.State)
	}
	if info.Command != "ssh remote" {
		t.Errorf("command = %q, want the OSC command line to survive", info.Command)
	}

	s.SetRemoteState(true, "ssh")
	if got := s.Info().State; got != StateRunning {
		t.Errorf("state = %s, want running", got)
	}
	if s.RunStarted.IsZero() {
		t.Error("RunStarted was not recorded on the transition to running")
	}
}

func TestSetRemoteStateFillsMissingCommand(t *testing.T) {
	s := &Session{State: StateIdle}
	s.SetRemoteState(true, "ssh")
	if got := s.Info().Command; got != "ssh" {
		t.Errorf("command = %q, want %q", got, "ssh")
	}
}

func TestSetRemoteStateLeavesTerminalStates(t *testing.T) {
	for _, st := range []State{StateExited, StateStarting} {
		s := &Session{State: st}
		s.SetRemoteState(false, "ssh")
		if got := s.Info().State; got != st {
			t.Errorf("state = %s, want %s untouched", got, st)
		}
	}
}
