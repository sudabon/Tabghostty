package agentdetect

import (
	"reflect"
	"strings"
	"testing"
)

func TestManifestRejectsActionAndResponse(t *testing.T) {
	for _, field := range []string{"action", "response"} {
		_, err := decodeManifest("x.json", validJSON("claude", map[string]any{field: "do-it"}))
		if err == nil {
			t.Fatalf("accepted %s field", field)
		}
	}
}

func TestRawManifestHasNoActionFields(t *testing.T) {
	typ := reflect.TypeOf(rawManifest{})
	for i := 0; i < typ.NumField(); i++ {
		name := strings.ToLower(typ.Field(i).Name)
		jsonTag := strings.ToLower(typ.Field(i).Tag.Get("json"))
		if strings.Contains(name, "action") || strings.Contains(name, "response") ||
			strings.Contains(jsonTag, "action") || strings.Contains(jsonTag, "response") {
			t.Fatalf("manifest exposes %s", typ.Field(i).Name)
		}
	}
}

func TestEngineAPIIsObservationOnly(t *testing.T) {
	for _, typ := range []reflect.Type{reflect.TypeOf(&Engine{}), reflect.TypeOf(&Detector{})} {
		for i := 0; i < typ.NumMethod(); i++ {
			name := strings.ToLower(typ.Method(i).Name)
			switch {
			case strings.Contains(name, "write"),
				strings.Contains(name, "kill"),
				strings.Contains(name, "signalprocess"),
				strings.Contains(name, "approve"),
				strings.Contains(name, "respond"):
				t.Fatalf("%s exposes %s", typ, typ.Method(i).Name)
			}
		}
	}
}

func TestScreenProviderHasOnlySnapshot(t *testing.T) {
	typ := reflect.TypeOf((*ScreenProvider)(nil)).Elem()
	if typ.NumMethod() != 1 || typ.Method(0).Name != "Snapshot" {
		t.Fatalf("ScreenProvider methods = %d", typ.NumMethod())
	}
}
