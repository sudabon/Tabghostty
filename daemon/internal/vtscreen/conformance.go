package vtscreen

import (
	"fmt"
	"strings"
	"testing"
)

func runConformance(t *testing.T, factory Factory, skip map[string]bool) {
	t.Helper()
	for _, fx := range ConformanceFixtures() {
		t.Run(fx.Name, func(t *testing.T) {
			if skip[fx.Name] {
				t.Skip("not applicable for this implementation")
			}
			s, err := factory(fx.Cols, fx.Rows)
			if err != nil {
				t.Fatalf("factory: %v", err)
			}
			t.Cleanup(func() { _ = s.Close() })
			for i, op := range fx.Ops {
				if len(op.Feed) > 0 {
					if err := s.Feed(op.Feed); err != nil {
						t.Fatalf("op %d feed: %v", i, err)
					}
				}
				if op.ResizeCols > 0 && op.ResizeRows > 0 {
					if err := s.Resize(op.ResizeCols, op.ResizeRows); err != nil {
						t.Fatalf("op %d resize: %v", i, err)
					}
				}
				if op.Check == nil {
					continue
				}
				got := s.Snapshot(SnapshotOptions{Buffer: op.Check.Buffer, Lines: op.Check.Lines})
				if err := matchExpect(got, *op.Check); err != nil {
					t.Fatalf("op %d: %v\ngot lines %#v", i, err, got.Lines)
				}
			}
		})
	}
}

func matchExpect(got Snapshot, want FixtureExpect) error {
	if !got.Available {
		return fmt.Errorf("snapshot unavailable")
	}
	if want.Cols != 0 && got.Cols != want.Cols {
		return fmt.Errorf("cols = %d, want %d", got.Cols, want.Cols)
	}
	if want.Rows != 0 && got.Rows != want.Rows {
		return fmt.Errorf("rows = %d, want %d", got.Rows, want.Rows)
	}
	if want.Active != "" && got.Active != want.Active {
		return fmt.Errorf("active = %s, want %s", got.Active, want.Active)
	}
	if want.Buffer != "" && want.Buffer != BufferActive && got.Buffer != want.Buffer {
		return fmt.Errorf("buffer = %s, want %s", got.Buffer, want.Buffer)
	}
	if len(got.Lines) != len(want.Text) {
		return fmt.Errorf("line count = %d, want %d", len(got.Lines), len(want.Text))
	}
	for i := range want.Text {
		if !visualEqual(got.Lines[i], want.Text[i]) {
			return fmt.Errorf("line[%d] = %q, want %q", i, got.Lines[i], want.Text[i])
		}
	}
	return nil
}

func visualEqual(got, want string) bool {
	return foldCombining(got) == foldCombining(want)
}

func foldCombining(s string) string {
	s = strings.ReplaceAll(s, "e\u0301", "é")
	s = strings.ReplaceAll(s, "E\u0301", "É")
	return s
}
