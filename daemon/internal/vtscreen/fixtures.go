package vtscreen

// Fixture is a raw VT conformance case independent of any emulator library.
type Fixture struct {
	Name string
	Cols int
	Rows int
	Ops  []FixtureOp
}

// FixtureOp is one feed, resize, or snapshot expectation.
type FixtureOp struct {
	Feed       []byte
	ResizeCols int
	ResizeRows int
	Check      *FixtureExpect
}

// FixtureExpect is the normalized snapshot a conforming adapter must produce.
type FixtureExpect struct {
	Buffer BufferKind
	Lines  int
	Cols   int
	Rows   int
	Active BufferKind
	Text   []string
}

// ConformanceFixtures covers the mandatory screen-model sequences.
func ConformanceFixtures() []Fixture {
	return []Fixture{
		primaryScreenEdits(),
		decset1049Independent(),
		decset1049SameChunk(),
		decstbmScrollRegion(),
		cursorEraseAndMovement(),
		combiningMarks(),
		japaneseWideGlyphs(),
		resizeGeometry(),
	}
}

func primaryScreenEdits() Fixture {
	return Fixture{
		Name: "primary-screen-edits",
		Cols: 20,
		Rows: 4,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2Jhello world")},
			{Feed: []byte("\x1b[1;7HXXX")},
			{Check: &FixtureExpect{
				Buffer: BufferPrimary,
				Lines:  4,
				Cols:   20,
				Rows:   4,
				Active: BufferPrimary,
				Text:   []string{"hello XXXld", "", "", ""},
			}},
		},
	}
}

func decset1049Independent() Fixture {
	return Fixture{
		Name: "decset-decrst-1049",
		Cols: 16,
		Rows: 3,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2JPRIMARY")},
			{Feed: []byte("\x1b[?1049h\x1b[H\x1b[2JALT")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  3,
				Cols:   16,
				Rows:   3,
				Active: BufferAlternate,
				Text:   []string{"ALT", "", ""},
			}},
			{Check: &FixtureExpect{
				Buffer: BufferPrimary,
				Lines:  3,
				Active: BufferAlternate,
				Text:   []string{"PRIMARY", "", ""},
			}},
			{Feed: []byte("\x1b[?1049l")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  3,
				Active: BufferPrimary,
				Text:   []string{"PRIMARY", "", ""},
			}},
			{Check: &FixtureExpect{
				Buffer: BufferAlternate,
				Lines:  3,
				Active: BufferPrimary,
				Text:   []string{"ALT", "", ""},
			}},
		},
	}
}

func decset1049SameChunk() Fixture {
	return Fixture{
		Name: "decset-1049-same-chunk",
		Cols: 16,
		Rows: 3,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2JPRIMARY\x1b[?1049h\x1b[H\x1b[2JALT")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  3,
				Active: BufferAlternate,
				Text:   []string{"ALT", "", ""},
			}},
			{Check: &FixtureExpect{
				Buffer: BufferPrimary,
				Lines:  3,
				Active: BufferAlternate,
				Text:   []string{"PRIMARY", "", ""},
			}},
		},
	}
}

func decstbmScrollRegion() Fixture {
	return Fixture{
		Name: "decstbm-scroll-region",
		Cols: 12,
		Rows: 5,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2J\x1b[1;1Hfixed-top\x1b[5;1Hfixed-bot")},
			{Feed: []byte("\x1b[2;4r\x1b[2;1Ha\r\nb\r\nc\r\nd")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  5,
				Cols:   12,
				Rows:   5,
				Active: BufferPrimary,
				Text:   []string{"fixed-top", "b", "c", "d", "fixed-bot"},
			}},
		},
	}
}

func cursorEraseAndMovement() Fixture {
	return Fixture{
		Name: "cursor-erase-movement",
		Cols: 10,
		Rows: 3,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2JABCDEF\x1b[1;4H\x1b[K")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  3,
				Text:   []string{"ABC", "", ""},
			}},
			{Feed: []byte("\x1b[H\x1b[2JABCDEF\x1b[1;4H\x1b[2K\x1b[2;3HXY")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  3,
				Text:   []string{"", "  XY", ""},
			}},
		},
	}
}

func combiningMarks() Fixture {
	return Fixture{
		Name: "combining-marks",
		Cols: 8,
		Rows: 1,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2Jcafe\u0301")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  1,
				Text:   []string{"café"},
			}},
		},
	}
}

func japaneseWideGlyphs() Fixture {
	return Fixture{
		Name: "japanese-wide-glyphs",
		Cols: 12,
		Rows: 2,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2J日本語\x1b[1;7HX")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  2,
				Text:   []string{"日本語X", ""},
			}},
			{Feed: []byte("\x1b[2;1H日A")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  2,
				Text:   []string{"日本語X", "日A"},
			}},
		},
	}
}

func resizeGeometry() Fixture {
	return Fixture{
		Name: "resize",
		Cols: 80,
		Rows: 24,
		Ops: []FixtureOp{
			{Feed: []byte("\x1b[H\x1b[2JHELLO")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  24,
				Cols:   80,
				Rows:   24,
				Text:   prefixLines("HELLO", 24),
			}},
			{ResizeCols: 40, ResizeRows: 10},
			{Feed: []byte("\x1b[H\x1b[2JZ")},
			{Check: &FixtureExpect{
				Buffer: BufferActive,
				Lines:  10,
				Cols:   40,
				Rows:   10,
				Text:   prefixLines("Z", 10),
			}},
		},
	}
}

func prefixLines(first string, rows int) []string {
	out := make([]string, rows)
	out[0] = first
	return out
}
