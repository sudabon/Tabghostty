package agentfixtures

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

type secretRule struct {
	name string
	re   *regexp.Regexp
}

var credentialRules = []secretRule{
	{name: "openai-sk", re: regexp.MustCompile(`sk-[A-Za-z0-9_-]{10,}`)},
	{name: "github-pat", re: regexp.MustCompile(`ghp_[A-Za-z0-9]{20,}`)},
	{name: "github-oauth", re: regexp.MustCompile(`gho_[A-Za-z0-9]{20,}`)},
	{name: "slack-token", re: regexp.MustCompile(`xox[baprs]-[A-Za-z0-9-]{10,}`)},
	{name: "aws-access-key", re: regexp.MustCompile(`AKIA[0-9A-Z]{16}`)},
	{name: "bearer-token", re: regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*`)},
	{name: "api-key-assignment", re: regexp.MustCompile(`(?i)(api[_-]?key|secret[_-]?key)\s*[:=]\s*\S+`)},
	{name: "private-key-block", re: regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)},
	{name: "anthropic-key", re: regexp.MustCompile(`sk-ant-[A-Za-z0-9_-]{10,}`)},
}

var homePathRules = []secretRule{
	{name: "macos-home", re: regexp.MustCompile(`/Users/[A-Za-z0-9._-]+`)},
	{name: "linux-home", re: regexp.MustCompile(`/home/[A-Za-z0-9._-]+`)},
	{name: "root-home", re: regexp.MustCompile(`(?m)(?:\s|^)/root(?:/|\s|$)`)},
}

// SafetyIssue identifies a file that failed a secret or home-path check
// without including the matched secret value.
type SafetyIssue struct {
	File string
	Rule string
	Kind string
}

func (s SafetyIssue) Error() string {
	return fmt.Sprintf("%s: %s pattern %q matched (value omitted)", s.File, s.Kind, s.Rule)
}

// CheckSafety scans fixture files for configured credential patterns and absolute home paths.
func CheckSafety(fx Fixture) []SafetyIssue {
	files := []struct {
		name string
		data []byte
	}{
		{StreamName, fx.Stream},
	}
	if raw, err := os.ReadFile(filepath.Join(fx.Dir, MetadataName)); err == nil {
		files = append(files, struct {
			name string
			data []byte
		}{MetadataName, raw})
	}
	if raw, err := os.ReadFile(filepath.Join(fx.Dir, CaseName)); err == nil {
		files = append(files, struct {
			name string
			data []byte
		}{CaseName, raw})
	}
	var issues []SafetyIssue
	label := func(name string) string {
		if fx.Dir == "" {
			return name
		}
		return filepath.Join(fx.Dir, name)
	}
	for _, f := range files {
		text := string(f.data)
		if !utf8.Valid(f.data) {
			text = strings.ToValidUTF8(string(f.data), "")
		}
		for _, rule := range credentialRules {
			if rule.re.MatchString(text) {
				issues = append(issues, SafetyIssue{File: label(f.name), Rule: rule.name, Kind: "credential"})
			}
		}
		for _, rule := range homePathRules {
			if rule.re.MatchString(text) {
				issues = append(issues, SafetyIssue{File: label(f.name), Rule: rule.name, Kind: "home-path"})
			}
		}
	}
	return issues
}
