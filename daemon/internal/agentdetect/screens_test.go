// Tabghostty: reference screens for engine parity (openspec/changes/phase6-daemon-ghostty-screen design D2).
// Not part of upstream webtabinal; see daemon/UPSTREAM.md.
//
//	go test -tags ghostty ./internal/agentdetect -run TestFixtureReferenceScreens -update-screens
//
// writes screen.txt and screen.meta.json next to every agent fixture. Without the flag, a ghostty build
// checks that the committed screen.txt still matches the screen model. The default (charmbracelet)
// build neither writes nor checks reference screens.

package agentdetect

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sudabon/webtabinal/internal/agentfixtures"
	"github.com/sudabon/webtabinal/internal/vtscreen"
)

var updateScreens = flag.Bool("update-screens", false, "write screen.txt and screen.meta.json for every agent fixture (ghostty build only)")

const (
	referenceScreenFile   = "screen.txt"
	referenceMetadataFile = "screen.meta.json"
)

// referenceMetadata is screen.meta.json. Tabghostty's EngineParityTests reads these fields.
type referenceMetadata struct {
	ScreenModel         string `json:"screen_model"`
	LibghosttyVtVersion string `json:"libghostty_vt_version"`
}

func TestFixtureReferenceScreens(t *testing.T) {
	if vtscreen.ModelName != "ghostty" {
		t.Skipf("reference screens come from the ghostty screen model; this build uses %s (use -tags ghostty)", vtscreen.ModelName)
	}
	root, err := agentfixtures.Root()
	if err != nil {
		t.Fatal(err)
	}
	fixtures, err := agentfixtures.Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(fixtures) == 0 {
		t.Fatalf("no fixtures under %s", root)
	}
	metadata := referenceMetadata{ScreenModel: vtscreen.ModelName, LibghosttyVtVersion: vtscreen.LibraryVersion()}
	for _, fx := range fixtures {
		name, _ := filepath.Rel(root, fx.Dir)
		t.Run(name, func(t *testing.T) {
			lines, err := fixtureFinalScreen(fx)
			if err != nil {
				t.Fatal(err)
			}
			screen := []byte(strings.Join(lines, "\n") + "\n")
			screenPath := filepath.Join(fx.Dir, referenceScreenFile)
			metadataPath := filepath.Join(fx.Dir, referenceMetadataFile)
			if *updateScreens {
				if err := os.WriteFile(screenPath, screen, 0o644); err != nil {
					t.Fatal(err)
				}
				encoded, err := json.MarshalIndent(metadata, "", "  ")
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(metadataPath, append(encoded, '\n'), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(screenPath)
			if os.IsNotExist(err) {
				t.Skipf("%s has no %s (run make screens)", name, referenceScreenFile)
			}
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(want, screen) {
				t.Fatalf("%s/%s is stale (run make screens)\ncommitted:\n%s\ncurrent:\n%s", name, referenceScreenFile, want, screen)
			}
			var recorded referenceMetadata
			raw, err := os.ReadFile(metadataPath)
			if err != nil {
				t.Fatalf("%s/%s: %v", name, referenceMetadataFile, err)
			}
			if err := json.Unmarshal(raw, &recorded); err != nil {
				t.Fatalf("%s/%s: %v", name, referenceMetadataFile, err)
			}
			if recorded != metadata {
				t.Fatalf("%s/%s = %+v, current build %+v (run make screens)", name, referenceMetadataFile, recorded, metadata)
			}
		})
	}
}

// fixtureFinalScreen feeds a fixture's steps the way replayFixture does and returns
// the final active screen at the fixture's geometry.
func fixtureFinalScreen(fx agentfixtures.Fixture) ([]string, error) {
	screen, err := vtscreen.Open(vtscreen.Options{Cols: fx.Meta.Columns, Rows: fx.Meta.Rows, Name: fx.Scenario})
	if err != nil {
		return nil, fmt.Errorf("%s: vt open: %w", fx.Dir, err)
	}
	defer screen.Close()
	for _, step := range fx.Case.Steps {
		if err := screen.Feed(fx.Stream[step.ByteStart:step.ByteEnd]); err != nil {
			return nil, fmt.Errorf("%s step %s: feed: %w", fx.Dir, step.Name, err)
		}
	}
	snap := screen.Snapshot(vtscreen.SnapshotOptions{Buffer: vtscreen.BufferActive, Lines: fx.Meta.Rows})
	if !snap.Available {
		return nil, fmt.Errorf("%s: screen model unavailable", fx.Dir)
	}
	return snap.Lines, nil
}
