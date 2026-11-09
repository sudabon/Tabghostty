package agentfixtures

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadRejectsMissingMetadataFields(t *testing.T) {
	dir := writeScenario(t, Metadata{
		SchemaVersion:      1,
		Agent:              "claude",
		Version:            "v",
		Scenario:           "idle",
		Rows:               24,
		Columns:            80,
		TERM:               "xterm-256color",
		Locale:             "en_US.UTF-8",
		Platform:           "darwin",
		CaptureToolVersion: CaptureToolVersion,
		Reviewed:           true,
	}, CaseFile{
		SchemaVersion: 1,
		Identity:      Identity{Command: "claude"},
		Steps: []Step{{
			Name:      "feed",
			ByteEnd:   3,
			AdvanceMS: 120,
			Expect:    Expect{AgentID: "claude", State: "idle", Signal: "screen"},
		}},
	}, []byte("abc"))

	metaPath := filepath.Join(dir, MetadataName)
	raw, err := os.ReadFile(metaPath)
	if err != nil {
		t.Fatal(err)
	}
	stripped := strings.Replace(string(raw), `"term": "xterm-256color",`, "", 1)
	if err := os.WriteFile(metaPath, []byte(stripped), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir); err == nil {
		t.Fatal("expected missing term to fail")
	}
}

func TestLoadRejectsOversizedStream(t *testing.T) {
	dir := writeScenario(t, validMeta(), validCase(3), []byte("abc"))
	huge := make([]byte, MaxFileBytes+1)
	if err := os.WriteFile(filepath.Join(dir, StreamName), huge, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(dir); err == nil || !strings.Contains(err.Error(), "exceeds limit") {
		t.Fatalf("oversized stream: %v", err)
	}
}

func TestLoadRejectsByteRangePastEOF(t *testing.T) {
	c := validCase(3)
	c.Steps[0].ByteEnd = 99
	dir := writeScenario(t, validMeta(), c, []byte("abc"))
	if _, err := Load(dir); err == nil || !strings.Contains(err.Error(), "exceeds stream") {
		t.Fatalf("out of range: %v", err)
	}
}

func TestSafetyDetectsCredentialWithoutPrintingValue(t *testing.T) {
	secret := "sk-ant-api03-THISISNOTAREALKEYVALUE123456"
	fx := Fixture{
		Dir:    t.TempDir(),
		Stream: []byte("output " + secret + " done"),
	}
	issues := CheckSafety(fx)
	if len(issues) == 0 {
		t.Fatal("expected credential issue")
	}
	for _, issue := range issues {
		if strings.Contains(issue.Error(), secret) {
			t.Fatalf("secret leaked: %s", issue.Error())
		}
		if issue.Kind != "credential" {
			t.Fatalf("kind = %s", issue.Kind)
		}
	}
}

func TestSafetyDetectsHomePath(t *testing.T) {
	fx := Fixture{Dir: t.TempDir(), Stream: []byte("cwd /Users/example/src\n")}
	issues := CheckSafety(fx)
	if len(issues) == 0 {
		t.Fatal("expected home-path issue")
	}
	if issues[0].Kind != "home-path" {
		t.Fatalf("kind = %s", issues[0].Kind)
	}
}

func validMeta() Metadata {
	return Metadata{
		SchemaVersion:      1,
		Agent:              "claude",
		Version:            "v",
		Scenario:           "idle",
		Rows:               24,
		Columns:            80,
		TERM:               "xterm-256color",
		Locale:             "en_US.UTF-8",
		Platform:           "test",
		CaptureToolVersion: CaptureToolVersion,
		Reviewed:           true,
	}
}

func validCase(n int) CaseFile {
	return CaseFile{
		SchemaVersion: 1,
		Identity:      Identity{Command: "claude"},
		Steps: []Step{{
			Name:      "feed",
			ByteEnd:   n,
			AdvanceMS: 120,
			Expect:    Expect{AgentID: "claude", State: "idle", Signal: "screen"},
		}},
	}
}

func writeScenario(t *testing.T, meta Metadata, c CaseFile, stream []byte) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, meta.Agent, meta.Version, meta.Scenario)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	mustJSON(t, filepath.Join(dir, MetadataName), meta)
	mustJSON(t, filepath.Join(dir, CaseName), c)
	if err := os.WriteFile(filepath.Join(dir, StreamName), stream, 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func mustJSON(t *testing.T, path string, v any) {
	t.Helper()
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}
