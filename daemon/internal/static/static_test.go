package static

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestIsPlaceholderMatchesEmbeddedIndex(t *testing.T) {
	b, err := distEmbed.ReadFile("dist/index.html")
	if err != nil {
		if !IsPlaceholder() {
			t.Fatal("missing dist/index.html, want IsPlaceholder() true")
		}
		return
	}
	want := strings.Contains(string(b), placeholderMarker)
	if got := IsPlaceholder(); got != want {
		t.Fatalf("IsPlaceholder() = %v, want %v", got, want)
	}
}

func TestHandlerServesPlaceholderWhenDistIsStub(t *testing.T) {
	h := Handler()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	hasMarker := strings.Contains(rec.Body.String(), placeholderMarker)
	if hasMarker != IsPlaceholder() {
		t.Fatalf("body has placeholder marker = %v, IsPlaceholder() = %v", hasMarker, IsPlaceholder())
	}
}

func TestHandlerDisablesCacheForAppShell(t *testing.T) {
	h := Handler()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-cache" {
		t.Fatalf("Cache-Control = %q, want no-cache", got)
	}
}
