package agentdetect

import (
	"testing"

	"github.com/sudabon/webtabinal/internal/agentfixtures"
)

func TestGoldenFixturesReplay(t *testing.T) {
	root, err := agentfixtures.Root()
	if err != nil {
		t.Fatal(err)
	}
	fixtures, err := agentfixtures.Discover(root)
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	if len(fixtures) == 0 {
		t.Fatal("no fixtures discovered")
	}
	reg := Load(LoadOptions{DisableLocal: true})
	for _, fx := range fixtures {
		fx := fx
		t.Run(fx.Agent+"/"+fx.Version+"/"+fx.Scenario, func(t *testing.T) {
			if _, err := replayFixture(fx, reg); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestVerifiedAgainstHasMatchingFixtures(t *testing.T) {
	root, err := agentfixtures.Root()
	if err != nil {
		t.Fatal(err)
	}
	fixtures, err := agentfixtures.Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	byKey := map[string][]agentfixtures.Fixture{}
	for _, fx := range fixtures {
		if !fx.Meta.Reviewed {
			t.Errorf("%s: committed fixture is not reviewed", fx.Dir)
		}
		key := fx.Agent + "/" + fx.Version
		byKey[key] = append(byKey[key], fx)
	}
	reg := Load(LoadOptions{DisableLocal: true})
	for _, id := range reg.IDs() {
		if id == IDGeneric {
			continue
		}
		m, ok := reg.Manifest(id)
		if !ok {
			t.Fatalf("missing %s", id)
		}
		if len(m.VerifiedAgainst) == 0 {
			t.Fatalf("%s has empty verified_against", id)
		}
		for _, ver := range m.VerifiedAgainst {
			list := byKey[id+"/"+ver]
			if len(list) == 0 {
				t.Fatalf("%s verified_against %q has no fixture directory", id, ver)
			}
			for _, fx := range list {
				if fx.Meta.Agent != id || fx.Meta.Version != ver {
					t.Fatalf("metadata mismatch %+v vs %s/%s", fx.Meta, id, ver)
				}
			}
		}
	}
}

func TestManifestPatternsPositiveAndNegative(t *testing.T) {
	root, err := agentfixtures.Root()
	if err != nil {
		t.Fatal(err)
	}
	fixtures, err := agentfixtures.Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	reg := Load(LoadOptions{DisableLocal: true})
	for _, id := range []string{IDClaude, IDCodex, IDCursor} {
		m, ok := reg.Manifest(id)
		if !ok {
			if id == IDCursor {
				continue
			}
			t.Fatalf("missing %s", id)
		}
		for _, fx := range fixtures {
			if fx.Agent != id {
				continue
			}
			results, err := replayFixture(fx, reg)
			if err != nil {
				t.Fatal(err)
			}
			lines := results[len(results)-1].Lines
			hits := MatchManifest(m, lines)
			last := fx.Case.Steps[len(fx.Case.Steps)-1].Expect.State
			blockedHit := false
			workingHit := false
			for _, h := range hits {
				switch h.State {
				case StateBlocked:
					blockedHit = true
					if last != string(StateBlocked) {
						t.Errorf("%s blocked pattern %s matched negative fixture %s/%s", id, h.ID, fx.Version, fx.Scenario)
					}
				case StateWorking:
					workingHit = true
				}
			}
			if last == string(StateBlocked) && len(m.Blocked) > 0 && !blockedHit {
				t.Errorf("%s blocked fixture %s matched no blocked pattern", id, fx.Scenario)
			}
			if last == string(StateWorking) && len(m.Working) > 0 && !workingHit && fx.Scenario != "transitions" {
				t.Errorf("%s working fixture %s matched no working pattern", id, fx.Scenario)
			}
		}
	}
}

func TestCommittedFixturesPassSafety(t *testing.T) {
	root, err := agentfixtures.Root()
	if err != nil {
		t.Fatal(err)
	}
	fixtures, err := agentfixtures.Discover(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, fx := range fixtures {
		for _, issue := range agentfixtures.CheckSafety(fx) {
			t.Errorf("%s", issue.Error())
		}
	}
}
