package session

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// localeVars decide the character encoding a child process picks, in POSIX
// precedence order.
var localeVars = map[string]bool{"LC_ALL": true, "LC_CTYPE": true, "LANG": true}

const fallbackLocale = "en_US.UTF-8"

// detectUTF8Locale reports the UTF-8 locale to hand to shells that inherit
// none. A GUI-launched daemon gets no locale from launchd, and without one
// vim opens UTF-8 files as latin1.
var detectUTF8Locale = sync.OnceValue(func() string {
	return utf8LocaleFor(systemLocale(), localeInstalled)
})

// withLocaleEnv adds LANG when env carries no locale of its own. An existing
// locale is left alone, whatever it is: the user chose it.
func withLocaleEnv(env []string, locale string) []string {
	if locale == "" {
		return env
	}
	out := make([]string, 0, len(env)+1)
	for _, e := range env {
		key, value, _ := strings.Cut(e, "=")
		if localeVars[key] {
			if value != "" {
				return env
			}
			continue
		}
		out = append(out, e)
	}
	return append(out, "LANG="+locale)
}

// utf8LocaleFor turns a macOS AppleLocale such as "ja_JP" into its POSIX
// UTF-8 equivalent, falling back when the pair is not installed. Region and
// language are set separately in System Settings, so combinations like
// "en_JP" that macOS ships no locale for are routine.
func utf8LocaleFor(appleLocale string, available func(string) bool) string {
	name, _, _ := strings.Cut(appleLocale, "@")
	lang, region, ok := strings.Cut(name, "_")
	if !ok {
		return fallbackLocale
	}
	lang, _, _ = strings.Cut(lang, "-") // drop script subtags, e.g. zh-Hans_CN
	candidate := lang + "_" + region + ".UTF-8"
	if !available(candidate) {
		return fallbackLocale
	}
	return candidate
}

func systemLocale() string {
	out, err := exec.Command("defaults", "read", "-g", "AppleLocale").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func localeInstalled(locale string) bool {
	_, err := os.Stat(filepath.Join("/usr/share/locale", locale))
	return err == nil
}
