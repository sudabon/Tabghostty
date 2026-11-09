package session

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSetMemoTrimsAndStores(t *testing.T) {
	s := &Session{}
	if err := s.SetMemo("  CI watch  "); err != nil {
		t.Fatal(err)
	}
	if got := s.Info().Memo; got != "CI watch" {
		t.Fatalf("memo = %q, want CI watch", got)
	}
}

func TestSetMemoRejectsOverLimit(t *testing.T) {
	s := &Session{}
	tooLong := strings.Repeat("あ", MaxMemoRunes+1)
	if utf8.RuneCountInString(tooLong) != MaxMemoRunes+1 {
		t.Fatalf("fixture length = %d", utf8.RuneCountInString(tooLong))
	}
	if err := s.SetMemo(tooLong); err == nil {
		t.Fatal("expected over-limit memo to fail")
	}
	if got := s.Info().Memo; got != "" {
		t.Fatalf("memo = %q, want empty after rejected set", got)
	}
}

func TestSetMemoAllowsExactLimit(t *testing.T) {
	s := &Session{}
	exact := strings.Repeat("あ", MaxMemoRunes)
	if err := s.SetMemo(exact); err != nil {
		t.Fatal(err)
	}
	if got := s.Info().Memo; got != exact {
		t.Fatalf("memo length = %d, want %d", utf8.RuneCountInString(got), MaxMemoRunes)
	}
}

func TestSetMemoClearsWithWhitespace(t *testing.T) {
	s := &Session{Memo: "keep"}
	if err := s.SetMemo("   "); err != nil {
		t.Fatal(err)
	}
	if got := s.Info().Memo; got != "" {
		t.Fatalf("memo = %q, want empty", got)
	}
}

func TestNewSessionInfoHasEmptyMemo(t *testing.T) {
	s := &Session{ID: "new"}
	if got := s.Info().Memo; got != "" {
		t.Fatalf("memo = %q, want empty", got)
	}
}
