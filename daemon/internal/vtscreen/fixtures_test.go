package vtscreen

import (
	"testing"
	"unicode"
	"unicode/utf8"
)

func TestConformanceFixturesCoverMandatoryCases(t *testing.T) {
	want := []string{
		"primary-screen-edits",
		"decset-decrst-1049",
		"decset-1049-same-chunk",
		"decstbm-scroll-region",
		"cursor-erase-movement",
		"combining-marks",
		"japanese-wide-glyphs",
		"resize",
	}
	got := ConformanceFixtures()
	if len(got) != len(want) {
		t.Fatalf("fixtures = %d, want %d", len(got), len(want))
	}
	for i, name := range want {
		if got[i].Name != name {
			t.Fatalf("fixture[%d] = %q, want %q", i, got[i].Name, name)
		}
		if got[i].Cols <= 0 || got[i].Rows <= 0 {
			t.Fatalf("%s: invalid geometry", name)
		}
		if len(got[i].Ops) == 0 {
			t.Fatalf("%s: no operations", name)
		}
		hasCheck := false
		for _, op := range got[i].Ops {
			if len(op.Feed) == 0 && op.ResizeCols == 0 && op.Check == nil {
				t.Fatalf("%s: empty operation", name)
			}
			if op.Check != nil {
				hasCheck = true
				if op.Check.Text == nil {
					t.Fatalf("%s: check missing expected text", name)
				}
			}
		}
		if !hasCheck {
			t.Fatalf("%s: no snapshot expectation", name)
		}
	}
}

func TestJapaneseFixtureUsesWideGlyphs(t *testing.T) {
	var f Fixture
	for _, fx := range ConformanceFixtures() {
		if fx.Name == "japanese-wide-glyphs" {
			f = fx
			break
		}
	}
	found := false
	for _, op := range f.Ops {
		for _, r := range string(op.Feed) {
			if unicode.In(r, unicode.Han) {
				found = true
			}
		}
	}
	if !found {
		t.Fatal("japanese fixture has no Han runes")
	}
}

func TestCombiningFixtureContainsMark(t *testing.T) {
	var f Fixture
	for _, fx := range ConformanceFixtures() {
		if fx.Name == "combining-marks" {
			f = fx
			break
		}
	}
	found := false
	for _, op := range f.Ops {
		for i := 0; i < len(op.Feed); {
			r, size := utf8.DecodeRune(op.Feed[i:])
			if unicode.Is(unicode.Mn, r) {
				found = true
			}
			i += size
		}
	}
	if !found {
		t.Fatal("combining fixture has no combining mark")
	}
}

func TestRunConformanceAgainstFakeCoversPlainAndAlt(t *testing.T) {
	runConformance(t, newFake, map[string]bool{
		"primary-screen-edits":  true,
		"decstbm-scroll-region": true,
		"cursor-erase-movement": true,
		"combining-marks":       true,
		"japanese-wide-glyphs":  true,
		"resize":                true,
	})
}
