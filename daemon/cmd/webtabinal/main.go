package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"

	"github.com/sudabon/webtabinal/internal/config"
	"github.com/sudabon/webtabinal/internal/imagedrop"
	"github.com/sudabon/webtabinal/internal/integration"
	"github.com/sudabon/webtabinal/internal/launchd"
	"github.com/sudabon/webtabinal/internal/logging"
	"github.com/sudabon/webtabinal/internal/paths"
	"github.com/sudabon/webtabinal/internal/restore"
	"github.com/sudabon/webtabinal/internal/server"
	"github.com/sudabon/webtabinal/internal/session"
	"github.com/sudabon/webtabinal/internal/static"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "serve":
		if err := runServe(); err != nil {
			fmt.Fprintf(os.Stderr, "serve error: %v\n", err)
			os.Exit(1)
		}
	case "state":
		opts, err := parseStateArgs(os.Args[2:])
		if err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			os.Exit(2)
		}
		cfg, err := config.LoadOrCreate()
		if err != nil {
			fatal(err)
		}
		os.Exit(runStateSnapshot(os.Stdout, os.Stderr, cfg, nil, opts))
	case "notify":
		opts, err := parseNotifyArgs(os.Args[2:], os.Getenv(sessionEnvVar))
		if err != nil {
			// Exit 1, never 2: a stop hook exiting 2 blocks the agent's turn,
			// and a mistyped flag must not wedge an agent.
			fmt.Fprintf(os.Stderr, "%v\n", err)
			os.Exit(1)
		}
		cfg, err := config.LoadOrCreate()
		if err != nil {
			os.Exit(0)
		}
		os.Exit(runNotify(os.Stdout, os.Stderr, cfg, nil, opts))
	case "hooks":
		os.Exit(runHooksPrint(os.Stdout, os.Stderr, os.Args[2:], resolvedExecutable()))
	case "install":
		bin := resolvedExecutable()
		if bin == "" {
			fatal(errors.New("cannot determine this binary's path"))
		}
		if err := launchd.Install(bin); err != nil {
			fatal(err)
		}
		fmt.Println("installed LaunchAgent", launchd.Label)
	case "uninstall":
		if err := launchd.Uninstall(); err != nil {
			fatal(err)
		}
		fmt.Println("uninstalled LaunchAgent")
	case "status":
		st, err := launchd.Status()
		if err != nil {
			fatal(err)
		}
		fmt.Println(st)
		cfg, err := config.LoadOrCreate()
		if err == nil {
			fmt.Printf("url: http://127.0.0.1:%d\n", cfg.Get().Port)
		}
	case "open":
		cfg, err := config.LoadOrCreate()
		if err != nil {
			fatal(err)
		}
		url := fmt.Sprintf("http://127.0.0.1:%d", cfg.Get().Port)
		var cmd *exec.Cmd
		if runtime.GOOS == "darwin" {
			cmd = exec.Command("open", url)
		} else {
			cmd = exec.Command("xdg-open", url)
		}
		if err := cmd.Start(); err != nil {
			fatal(err)
		}
		fmt.Println(url)
	default:
		usage()
		os.Exit(2)
	}
}

func runServe() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger, err := logging.Setup()
	if err != nil {
		return err
	}
	cfg, err := config.LoadOrCreate()
	if err != nil {
		return err
	}
	if err := integration.Write(); err != nil {
		return err
	}
	if integPath, err := paths.IntegrationPath(); err == nil {
		logger.Printf("zsh integration written to %s", integPath)
	}
	if bashPath, err := paths.BashIntegrationPath(); err == nil {
		logger.Printf("bash integration written to %s", bashPath)
	}

	mgr := session.NewManager(cfg, logger)
	defer mgr.Close()

	restorePath, err := paths.RestorePath()
	if err != nil {
		return err
	}
	// Before the server starts listening, so a client that attaches straight
	// away already sees the restored tabs.
	runRestore(mgr, cfg.Get().Restore, restorePath, logger)
	recorder := restore.StartRecorder(restore.RecorderOpts{
		Path:      restorePath,
		Observe:   func() []restore.Observed { return observedFrom(mgr.List()) },
		Overrides: func() map[string]string { return cfg.Get().Restore.Commands },
		Logger:    logger,
	})
	// Registered after mgr.Close, so this runs first and the final snapshot is
	// taken while the sessions are still alive.
	defer recorder.Stop()

	hub := server.NewHub(mgr, cfg, logger)
	if static.IsPlaceholder() {
		logger.Printf("warning: embedded frontend is a placeholder; run `make build` (not `go run` / `go build` alone) before serve")
	}
	srv := server.New(cfg, logger, hub, static.Handler())
	if dir, err := paths.ImagesDir(); err != nil {
		logger.Printf("warning: pasted images disabled: %v", err)
	} else {
		images := imagedrop.New(dir)
		// Sweep once at boot so a daemon that ran for weeks does not wait for
		// the next paste to drop images nobody will look at again.
		if removed, err := images.Prune(); err != nil {
			logger.Printf("warning: image prune: %v", err)
		} else if removed > 0 {
			logger.Printf("pruned %d stale pasted image(s) from %s", removed, dir)
		}
		srv.SetImageStore(images)
	}
	if err := srv.Run(ctx); err != nil {
		if errors.Is(err, server.ErrAlreadyRunning) {
			return nil
		}
		return err
	}
	return nil
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: %s <serve|install|uninstall|status|open|state|notify|hooks>\n", paths.CLIName)
	fmt.Fprintf(os.Stderr, "       %s state snapshot <session-id> [--lines N] [--buffer active|primary|alternate] [--json]\n", paths.CLIName)
	fmt.Fprintf(os.Stderr, "       %s\n", notifyUsage())
	fmt.Fprintf(os.Stderr, "       %s\n", hooksUsage())
}

// resolvedExecutable is this binary's real path, used wherever a pasted or
// installed configuration must keep pointing at it. Empty if it cannot be told.
func resolvedExecutable() string {
	bin, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(bin); err == nil {
		return resolved
	}
	return bin
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "%v\n", err)
	os.Exit(1)
}
