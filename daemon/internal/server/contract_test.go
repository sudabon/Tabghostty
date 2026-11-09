// Tabghostty: contract tests shared with the Swift client. Not part of upstream webtabinal.

package server

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var updateContract = flag.Bool("update-contract", false, "rewrite testdata/probe_unauthorized.http from the server's response")

// Tabghostty's probe (isWebTabinalProbeResponse in Sources/DesktopSupport) recognizes the daemon by
// its response to an unauthenticated GET /api/config. testdata/probe_unauthorized.http records the
// parts of that response the probe reads, and Tests/DesktopSupportTests checks that the probe accepts
// the recording. When a re-import of the daemon changes the response, this test fails; rerun it with
// -update-contract, and the Swift test then fails if the probe no longer recognizes the bundled daemon.
func TestUnauthorizedProbeResponseMatchesTheRecordedContract(t *testing.T) {
	store := testConfigStore(t)
	srv := New(store, log.New(io.Discard, "", 0), nil, nil)
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8642/api/config", nil)
	req.Host = "127.0.0.1:8642"
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)

	var b strings.Builder
	fmt.Fprintf(&b, "HTTP/1.1 %d %s\r\n", rec.Code, http.StatusText(rec.Code))
	for _, name := range []string{"Content-Security-Policy", "X-Content-Type-Options", "X-Frame-Options"} {
		fmt.Fprintf(&b, "%s: %s\r\n", name, rec.Header().Get(name))
	}
	b.WriteString("\r\n")
	b.WriteString(rec.Body.String())
	got := b.String()

	path := filepath.Join("testdata", "probe_unauthorized.http")
	if *updateContract {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with -update-contract to record it)", err)
	}
	if got != string(want) {
		t.Fatalf("the unauthenticated response changed (rerun with -update-contract, then run the Swift tests):\n%q\nwant\n%q", got, want)
	}
}
