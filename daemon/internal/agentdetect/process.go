//go:build unix

package agentdetect

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"github.com/sudabon/webtabinal/internal/vtscreen"
)

// PTYConn is the subset of *os.File used for foreground inspection.
type PTYConn interface {
	SyscallConn() (syscall.RawConn, error)
}

// SessionInspector inspects a session PTY's foreground process group.
// Inspection errors set Failed and must not fail the session.
type SessionInspector struct {
	PTY      PTYConn
	ShellPID int
	Screen   ScreenProvider
}

func (s SessionInspector) Inspect() ForegroundInfo {
	info := ForegroundInfo{Failed: true}
	if s.PTY == nil {
		return info
	}
	fgPID, err := foregroundPID(s.PTY)
	if err != nil || fgPID <= 0 {
		return info
	}
	info.Failed = false
	if s.ShellPID > 0 && fgPID == s.ShellPID {
		info.IsShell = true
		info.Executable = ""
	} else {
		name, anc, walkErr := walkAncestry(fgPID, s.ShellPID)
		info.Executable = name
		info.Ancestry = anc
		if walkErr != nil && name == "" {
			info.Executable = ""
		}
		info.IsShell = isShellName(name) || (s.ShellPID > 0 && fgPID == s.ShellPID)
	}
	if s.Screen != nil {
		snap := s.Screen.Snapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: 1})
		if snap.Available && snap.Active == vtscreen.BufferAlternate {
			info.UsingAlt = true
		}
	}
	return info
}

func foregroundPID(pty PTYConn) (int, error) {
	rc, err := pty.SyscallConn()
	if err != nil {
		return 0, err
	}
	var fg int32
	var errno syscall.Errno
	if err := rc.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(syscall.TIOCGPGRP), uintptr(unsafe.Pointer(&fg)))
	}); err != nil {
		return 0, err
	}
	if errno != 0 {
		return 0, errno
	}
	return int(fg), nil
}

func walkAncestry(fgPID, shellPID int) (exe string, ancestry []string, err error) {
	pid := fgPID
	seen := map[int]bool{}
	for pid > 0 && !seen[pid] {
		if shellPID > 0 && pid == shellPID {
			break
		}
		seen[pid] = true
		comm, ppid, perr := psCommPPID(pid)
		if perr != nil {
			if exe == "" {
				err = perr
			}
			break
		}
		if exe == "" {
			exe = comm
		} else if comm != "" {
			ancestry = append(ancestry, comm)
		}
		if ppid <= 1 || (shellPID > 0 && ppid == shellPID) {
			break
		}
		pid = ppid
	}
	return exe, ancestry, err
}

func psCommPPID(pid int) (comm string, ppid int, err error) {
	out, err := exec.Command("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", 0, err
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return "", 0, os.ErrNotExist
	}
	ppid, err = strconv.Atoi(fields[0])
	if err != nil {
		return "", 0, err
	}
	if len(fields) > 1 {
		comm = basename(strings.Join(fields[1:], " "))
	}
	return comm, ppid, nil
}
