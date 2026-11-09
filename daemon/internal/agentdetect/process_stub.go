//go:build !unix

package agentdetect

import "syscall"

// PTYConn is the subset of *os.File used for foreground inspection.
type PTYConn interface {
	SyscallConn() (syscall.RawConn, error)
}

// SessionInspector is a no-op inspector on unsupported platforms.
type SessionInspector struct {
	PTY      PTYConn
	ShellPID int
	Screen   ScreenProvider
}

func (s SessionInspector) Inspect() ForegroundInfo {
	return ForegroundInfo{Failed: true}
}
