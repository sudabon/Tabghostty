package session

import (
	"slices"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/osc"
)

func TestWithLocaleEnvAddsLangWhenUnset(t *testing.T) {
	got := withLocaleEnv([]string{"FOO=bar"}, "ja_JP.UTF-8")

	if !slices.Contains(got, "FOO=bar") {
		t.Fatalf("env = %#v, want FOO preserved", got)
	}
	if !slices.Contains(got, "LANG=ja_JP.UTF-8") {
		t.Fatalf("env = %#v, want LANG=ja_JP.UTF-8", got)
	}
}

func TestWithLocaleEnvKeepsUserLocale(t *testing.T) {
	for _, existing := range []string{"LANG=C", "LC_ALL=C", "LC_CTYPE=C"} {
		t.Run(existing, func(t *testing.T) {
			env := []string{"FOO=bar", existing}

			got := withLocaleEnv(env, "ja_JP.UTF-8")

			if !slices.Equal(got, env) {
				t.Fatalf("env = %#v, want unchanged %#v", got, env)
			}
		})
	}
}

func TestWithLocaleEnvReplacesEmptyLocaleVars(t *testing.T) {
	got := withLocaleEnv([]string{"LANG=", "FOO=bar"}, "ja_JP.UTF-8")

	if slices.Contains(got, "LANG=") {
		t.Fatalf("env = %#v, want empty LANG dropped", got)
	}
	if !slices.Contains(got, "LANG=ja_JP.UTF-8") {
		t.Fatalf("env = %#v, want LANG=ja_JP.UTF-8", got)
	}
}

func TestWithLocaleEnvWithoutLocaleLeavesEnvAlone(t *testing.T) {
	env := []string{"FOO=bar"}

	got := withLocaleEnv(env, "")

	if !slices.Equal(got, env) {
		t.Fatalf("env = %#v, want unchanged %#v", got, env)
	}
}

func TestUTF8LocaleFor(t *testing.T) {
	installed := map[string]bool{"ja_JP.UTF-8": true, "en_US.UTF-8": true, "zh_CN.UTF-8": true}
	available := func(locale string) bool { return installed[locale] }

	tests := []struct {
		name        string
		appleLocale string
		want        string
	}{
		{name: "installed locale", appleLocale: "ja_JP", want: "ja_JP.UTF-8"},
		{name: "keyword suffix", appleLocale: "ja_JP@calendar=japanese", want: "ja_JP.UTF-8"},
		{name: "script subtag", appleLocale: "zh-Hans_CN", want: "zh_CN.UTF-8"},
		{name: "uninstalled combination", appleLocale: "en_JP", want: "en_US.UTF-8"},
		{name: "language only", appleLocale: "ja", want: "en_US.UTF-8"},
		{name: "empty", appleLocale: "", want: "en_US.UTF-8"},
		{name: "malformed", appleLocale: "../../etc/passwd", want: "en_US.UTF-8"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := utf8LocaleFor(tt.appleLocale, available); got != tt.want {
				t.Fatalf("utf8LocaleFor(%q) = %q, want %q", tt.appleLocale, got, tt.want)
			}
		})
	}
}

func TestShellEnvSetsUTF8LocaleWhenUnset(t *testing.T) {
	t.Setenv("LANG", "")
	t.Setenv("LC_ALL", "")
	t.Setenv("LC_CTYPE", "")

	got := shellEnv("sid-1", osc.DarkPalette())

	var lang string
	for _, e := range got {
		if after, ok := strings.CutPrefix(e, "LANG="); ok {
			lang = after
		}
	}
	if !strings.HasSuffix(lang, ".UTF-8") {
		t.Fatalf("LANG = %q, want a .UTF-8 locale", lang)
	}
	if !slices.Contains(got, "WEBTABINAL_SESSION_ID=sid-1") {
		t.Fatalf("env = %#v, want session id preserved", got)
	}
	if !slices.Contains(got, "TERM=xterm-256color") {
		t.Fatalf("env = %#v, want TERM preserved", got)
	}
}
