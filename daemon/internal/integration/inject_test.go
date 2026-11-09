package integration

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/paths"
)

func TestApplyZshInjectionSetsZDOTDIR(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	env, err := ApplyZshInjection([]string{"HOME=" + home, "TERM=xterm"}, "/bin/zsh")
	if err != nil {
		t.Fatal(err)
	}
	zdot, err := paths.ZshInjectDir()
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(env, "ZDOTDIR"); got != zdot {
		t.Fatalf("ZDOTDIR = %q, want %q", got, zdot)
	}
	if got := envValue(env, "USER_ZDOTDIR"); got != home {
		t.Fatalf("USER_ZDOTDIR = %q, want %q", got, home)
	}
	if got := envValue(env, "WEBTABINAL_INJECTION"); got != "1" {
		t.Fatalf("WEBTABINAL_INJECTION = %q", got)
	}
	integ, err := paths.IntegrationPath()
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(env, "WEBTABINAL_INTEGRATION_PATH"); got != integ {
		t.Fatalf("WEBTABINAL_INTEGRATION_PATH = %q, want %q", got, integ)
	}
	for _, name := range []string{".zshenv", ".zprofile", ".zshrc", ".zlogin"} {
		path := filepath.Join(zdot, name)
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("inject file %s: %v", name, err)
		}
	}
}

func TestApplyZshInjectionSkipsNonZsh(t *testing.T) {
	in := []string{"HOME=/tmp"}
	out, err := ApplyZshInjection(in, "/bin/bash")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(out, "\x00") != strings.Join(in, "\x00") {
		t.Fatalf("env changed for bash: %#v", out)
	}
}

func TestApplyZshInjectionDoesNotNestInjectDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := Write(); err != nil {
		t.Fatal(err)
	}
	zdot, err := paths.ZshInjectDir()
	if err != nil {
		t.Fatal(err)
	}
	env, err := ApplyZshInjection([]string{
		"HOME=" + home,
		"ZDOTDIR=" + zdot,
		"USER_ZDOTDIR=" + home,
	}, "/bin/zsh")
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(env, "USER_ZDOTDIR"); got != home {
		t.Fatalf("USER_ZDOTDIR = %q, want %q", got, home)
	}
}

func TestApplyBashInjectionSetsEnvAndWritesFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	env, err := ApplyBashInjection([]string{"HOME=" + home, "TERM=xterm"}, "/opt/homebrew/bin/bash")
	if err != nil {
		t.Fatal(err)
	}
	integ, err := paths.BashIntegrationPath()
	if err != nil {
		t.Fatal(err)
	}
	if got := envValue(env, "WEBTABINAL_INTEGRATION_PATH"); got != integ {
		t.Fatalf("WEBTABINAL_INTEGRATION_PATH = %q, want %q", got, integ)
	}
	if got := envValue(env, "WEBTABINAL_INJECTION"); got != "1" {
		t.Fatalf("WEBTABINAL_INJECTION = %q", got)
	}
	if _, err := os.Stat(integ); err != nil {
		t.Fatalf("integration.bash: %v", err)
	}
	rc, err := paths.BashRcfile()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(rc); err != nil {
		t.Fatalf("bash rcfile: %v", err)
	}
}

func TestApplyBashInjectionSkipsNonBash(t *testing.T) {
	in := []string{"HOME=/tmp"}
	out, err := ApplyBashInjection(in, "/bin/zsh")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(out, "\x00") != strings.Join(in, "\x00") {
		t.Fatalf("env changed for zsh: %#v", out)
	}
}
