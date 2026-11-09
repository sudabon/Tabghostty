package agentdetect

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

func validJSON(id string, extra map[string]any) []byte {
	doc := map[string]any{
		"id":             id,
		"display_name":   id,
		"schema_version": 1,
		"match": map[string]any{
			"executables":      []string{id},
			"command_patterns": []string{id},
		},
		"screen": map[string]any{
			"bottom_lines": 15,
			"buffer":       "active",
			"states": map[string]any{
				"blocked": []any{},
				"working": []any{},
				"idle":    []any{},
			},
		},
		"authority": map[string]any{
			"blocked": []string{},
			"working": []string{"activity"},
			"idle":    []string{"screen+quiescence"},
		},
		"osc_authoritative":  false,
		"quiescence_ms":      1500,
		"activity_window_ms": 1000,
		"activity_min_bytes": 32,
		"verified_against":   []string{"test"},
	}
	if id == IDGeneric {
		doc["match"] = map[string]any{"executables": []string{}, "command_patterns": []string{}}
		doc["verified_against"] = []string{}
	}
	for k, v := range extra {
		doc[k] = v
	}
	b, err := json.Marshal(doc)
	if err != nil {
		panic(err)
	}
	return b
}

func TestBundledManifestsLoad(t *testing.T) {
	reg := Load(LoadOptions{DisableLocal: true})
	if len(reg.Errors()) != 0 {
		t.Fatalf("bundled errors: %v", reg.Errors())
	}
	for _, id := range []string{IDClaude, IDCodex, IDCursor, IDGeneric} {
		m, ok := reg.Manifest(id)
		if !ok {
			t.Fatalf("missing bundled %s", id)
		}
		if m.SchemaVersion != 1 {
			t.Fatalf("%s schema = %d", id, m.SchemaVersion)
		}
	}
	claude, _ := reg.Manifest(IDClaude)
	if len(claude.VerifiedAgainst) == 0 {
		t.Fatal("claude verified_against empty")
	}
	generic := reg.Generic()
	if generic == nil || len(generic.BlockedAuth) != 0 || len(generic.Blocked) != 0 {
		t.Fatalf("generic blocked not disabled: %+v", generic)
	}
}

func TestDuplicateBundledIDs(t *testing.T) {
	fsys := fstest.MapFS{
		"a.json": {Data: validJSON("claude", nil)},
		"b.json": {Data: validJSON("claude", map[string]any{"display_name": "other"})},
		"g.json": {Data: validJSON("generic", nil)},
	}
	reg := Load(LoadOptions{Bundled: fsys, DisableLocal: true})
	if len(reg.Errors()) == 0 {
		t.Fatal("expected duplicate id error")
	}
	if !strings.Contains(reg.Errors()[0].Error(), "duplicate id") {
		t.Fatalf("error = %v", reg.Errors()[0])
	}
}

func TestValidationFailures(t *testing.T) {
	cases := []struct {
		name  string
		extra map[string]any
		field string
		raw   string
	}{
		{name: "unknown-field", extra: map[string]any{"nope": 1}, field: "nope"},
		{name: "action-field", extra: map[string]any{"action": "type"}, field: "action"},
		{name: "response-field", extra: map[string]any{"response": "y"}, field: "response"},
		{name: "schema", extra: map[string]any{"schema_version": 2}, field: "schema_version"},
		{name: "buffer", extra: map[string]any{"screen": map[string]any{
			"bottom_lines": 15, "buffer": "scrollback", "states": map[string]any{"blocked": []any{}, "working": []any{}, "idle": []any{}},
		}}, field: "screen.buffer"},
		{name: "authority-enum", extra: map[string]any{"authority": map[string]any{
			"blocked": []string{"telepathy"}, "working": []string{"activity"}, "idle": []string{"osc"},
		}}, field: "authority.blocked"},
		{name: "missing-authority", extra: map[string]any{"authority": nil}, field: "authority"},
		{name: "bad-regex", extra: map[string]any{"screen": map[string]any{
			"bottom_lines": 15, "buffer": "active",
			"states": map[string]any{"blocked": []any{}, "working": []any{"[unterminated"}, "idle": []any{}},
		}}, field: "screen.states.working"},
		{name: "empty-regex", extra: map[string]any{"screen": map[string]any{
			"bottom_lines": 15, "buffer": "active",
			"states": map[string]any{"blocked": []any{}, "working": []any{""}, "idle": []any{}},
		}}},
		{name: "quiescence-range", extra: map[string]any{"quiescence_ms": 0}, field: "quiescence_ms"},
		{name: "activity-window-range", extra: map[string]any{"activity_window_ms": 999999}, field: "activity_window_ms"},
		{name: "bottom-lines", extra: map[string]any{"screen": map[string]any{
			"bottom_lines": 0, "buffer": "active", "states": map[string]any{"blocked": []any{}, "working": []any{}, "idle": []any{}},
		}}, field: "screen.bottom_lines"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var data []byte
			var err error
			if tc.raw != "" {
				data = []byte(tc.raw)
			} else {
				data = validJSON("claude", tc.extra)
			}
			_, err = decodeManifest(tc.name+".json", data)
			if err == nil {
				t.Fatal("expected error")
			}
			msg := err.Error()
			if strings.Contains(msg, "Do you want") || strings.Contains(msg, "esc to interrupt") {
				t.Fatalf("error leaked screen text: %v", err)
			}
			if tc.field != "" && !strings.Contains(msg, tc.field) {
				t.Fatalf("error %q, want field %q", msg, tc.field)
			}
		})
	}
}

func TestValidLocalOverrideWins(t *testing.T) {
	dir := t.TempDir()
	local := validJSON("codex", map[string]any{
		"display_name": "Local Codex",
		"screen": map[string]any{
			"bottom_lines": 8,
			"buffer":       "active",
			"states": map[string]any{
				"blocked": []any{},
				"working": []any{map[string]string{"id": "local-work", "pattern": "LOCAL_WORKING"}},
				"idle":    []any{},
			},
		},
	})
	if err := os.WriteFile(filepath.Join(dir, "codex.json"), local, 0o644); err != nil {
		t.Fatal(err)
	}
	reg := Load(LoadOptions{LocalDir: dir})
	m, ok := reg.Manifest(IDCodex)
	if !ok {
		t.Fatal("codex missing")
	}
	if m.DisplayName != "Local Codex" || m.BottomLines != 8 || len(m.Working) != 1 || m.Working[0].ID != "local-work" {
		t.Fatalf("override not applied: %+v", m)
	}
	if _, ok := reg.Manifest(IDClaude); !ok {
		t.Fatal("claude should remain bundled")
	}
}

func TestInvalidLocalSuppressesBundled(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "codex.json"), []byte(`{"id":"codex","schema_version":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	reg := Load(LoadOptions{LocalDir: dir})
	if _, ok := reg.Manifest(IDCodex); ok {
		t.Fatal("invalid local must not activate bundled codex")
	}
	if reg.Unavailable(IDCodex) == nil {
		t.Fatal("expected unavailable error")
	}
	if len(reg.Errors()) == 0 {
		t.Fatal("expected reported error")
	}
	if _, ok := reg.Manifest(IDGeneric); !ok {
		t.Fatal("generic should remain")
	}
}

func TestPostStartFileEditsDoNotMutateRegistry(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "codex.json")
	if err := os.WriteFile(path, validJSON("codex", map[string]any{"display_name": "Before"}), 0o644); err != nil {
		t.Fatal(err)
	}
	reg := Load(LoadOptions{LocalDir: dir})
	if err := os.WriteFile(path, validJSON("codex", map[string]any{"display_name": "After"}), 0o644); err != nil {
		t.Fatal(err)
	}
	m, _ := reg.Manifest(IDCodex)
	if m.DisplayName != "Before" {
		t.Fatalf("registry mutated after start: %q", m.DisplayName)
	}
}

func TestGenericBlockedRejected(t *testing.T) {
	_, err := decodeManifest("generic.json", validJSON("generic", map[string]any{
		"authority": map[string]any{
			"blocked": []string{"screen"},
			"working": []string{"activity"},
			"idle":    []string{"screen+quiescence"},
		},
	}))
	if err == nil {
		t.Fatal("expected generic blocked authority rejection")
	}
}

func TestDefaultManifestDir(t *testing.T) {
	t.Setenv("HOME", "/tmp/webtabinal-home")
	dir, err := DefaultManifestDir()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(dir, filepath.Join("Application Support", "WebTabinal", "manifests")) {
		t.Fatalf("dir = %q", dir)
	}
}
