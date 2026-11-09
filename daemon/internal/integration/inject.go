package integration

import (
	_ "embed"
	"os"
	"path/filepath"
	"strings"

	"github.com/sudabon/webtabinal/internal/paths"
)

//go:embed zdot/zshenv.zsh
var zshenvScript []byte

//go:embed zdot/zprofile.zsh
var zprofileScript []byte

//go:embed zdot/zshrc.zsh
var zshrcScript []byte

//go:embed zdot/zlogin.zsh
var zloginScript []byte

//go:embed bash-inject/bashrc
var bashrcScript []byte

// ApplyZshInjection writes inject files and returns env that makes zsh load
// WebTabinal OSC integration without a ~/.zshrc one-liner.
func ApplyZshInjection(env []string, shell string) ([]string, error) {
	if filepath.Base(shell) != "zsh" {
		return env, nil
	}
	if err := Write(); err != nil {
		return env, err
	}
	zdot, err := paths.ZshInjectDir()
	if err != nil {
		return env, err
	}
	integ, err := paths.IntegrationPath()
	if err != nil {
		return env, err
	}
	userZdot := envValue(env, "ZDOTDIR")
	if userZdot == "" {
		userZdot, err = os.UserHomeDir()
		if err != nil {
			return env, err
		}
	}
	if userZdot == zdot {
		if v := envValue(env, "USER_ZDOTDIR"); v != "" {
			userZdot = v
		} else {
			userZdot, err = os.UserHomeDir()
			if err != nil {
				return env, err
			}
		}
	}
	env = withoutKeys(env, "ZDOTDIR", "USER_ZDOTDIR", "WEBTABINAL_INJECTION", "WEBTABINAL_INTEGRATION_PATH")
	return append(env,
		"ZDOTDIR="+zdot,
		"USER_ZDOTDIR="+userZdot,
		"WEBTABINAL_INJECTION=1",
		"WEBTABINAL_INTEGRATION_PATH="+integ,
	), nil
}

// ApplyBashInjection writes inject files and returns env that makes bash load
// WebTabinal OSC integration without a ~/.bashrc one-liner.
func ApplyBashInjection(env []string, shell string) ([]string, error) {
	if filepath.Base(shell) != "bash" {
		return env, nil
	}
	if err := Write(); err != nil {
		return env, err
	}
	integ, err := paths.BashIntegrationPath()
	if err != nil {
		return env, err
	}
	env = withoutKeys(env, "WEBTABINAL_INJECTION", "WEBTABINAL_INTEGRATION_PATH")
	return append(env,
		"WEBTABINAL_INJECTION=1",
		"WEBTABINAL_INTEGRATION_PATH="+integ,
	), nil
}

func writeInjectFiles() error {
	dir, err := paths.ZshInjectDir()
	if err != nil {
		return err
	}
	if err := paths.EnsureDir(dir); err != nil {
		return err
	}
	files := map[string][]byte{
		".zshenv":   zshenvScript,
		".zprofile": zprofileScript,
		".zshrc":    zshrcScript,
		".zlogin":   zloginScript,
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), body, 0o644); err != nil {
			return err
		}
	}
	return nil
}

func writeBashFiles() error {
	path, err := paths.BashIntegrationPath()
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, bashScript, 0o644); err != nil {
		return err
	}
	dir, err := paths.BashInjectDir()
	if err != nil {
		return err
	}
	if err := paths.EnsureDir(dir); err != nil {
		return err
	}
	rc, err := paths.BashRcfile()
	if err != nil {
		return err
	}
	return os.WriteFile(rc, bashrcScript, 0o644)
}

func withoutKeys(env []string, keys ...string) []string {
	drop := make(map[string]struct{}, len(keys))
	for _, k := range keys {
		drop[k] = struct{}{}
	}
	out := make([]string, 0, len(env))
	for _, e := range env {
		k, _, _ := strings.Cut(e, "=")
		if _, ok := drop[k]; ok {
			continue
		}
		out = append(out, e)
	}
	return out
}

func envValue(env []string, key string) string {
	prefix := key + "="
	for i := len(env) - 1; i >= 0; i-- {
		if strings.HasPrefix(env[i], prefix) {
			return strings.TrimPrefix(env[i], prefix)
		}
	}
	return ""
}
