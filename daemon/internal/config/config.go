package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/sudabon/webtabinal/internal/paths"
)

type NotificationConfig struct {
	Enabled       bool `json:"enabled"`
	Always        bool `json:"always"`
	MinDurationMs int  `json:"min_duration_ms"`
	Sound         bool `json:"sound"`
	// Commands whitelists the session commands that may raise a desktop
	// banner. Matching uses the basename of the command's first token. An
	// empty list disables the restriction; notification.enabled turns
	// everything off.
	Commands []string `json:"commands"`
}

// DefaultNotifyCommands is the bundled coding-agent command set.
func DefaultNotifyCommands() []string {
	return []string{"claude", "codex", "cursor-agent", "agent"}
}

type StateConfig struct {
	Enabled         bool `json:"enabled"`
	DebounceMs      int  `json:"debounce_ms"`
	QuiescenceMs    int  `json:"quiescence_ms"`
	BottomLines     int  `json:"bottom_lines"`
	NotifyOnBlocked bool `json:"notify_on_blocked"`
	// NotifyOnIdle turns on the screen-derived prompt-return notification. It
	// defaults off: output quiescence cannot tell a finished turn from an agent
	// that merely paused to think, and an agent's stop hook reports the same
	// thing exactly. It stays available for agents without a usable hook.
	NotifyOnIdle bool   `json:"notify_on_idle"`
	ManifestDir  string `json:"manifest_dir"`
}

// RestoreConfig controls bringing coding-agent tabs back after the daemon
// stops. Commands maps an agent ID to the command a restored tab runs; an
// entry overrides the built-in for that agent and an explicit empty string
// disables restore for it. An empty map leaves every built-in in place.
type RestoreConfig struct {
	Enabled  bool              `json:"enabled"`
	Commands map[string]string `json:"commands"`
	// MaxSessions caps how many entries one restore pass recreates.
	MaxSessions int `json:"max_sessions"`
	// MaxAgeHours skips entries last observed longer ago than this. Zero
	// disables the age check, so it is never filled in from the default.
	MaxAgeHours int `json:"max_age_hours"`
}

type KeyBindingsConfig struct {
	Enabled       bool   `json:"enabled"`
	Prefix        string `json:"prefix"`
	NextTab       string `json:"next_tab"`
	PrevTab       string `json:"prev_tab"`
	ToggleSidebar string `json:"toggle_sidebar"`
}

// Color scheme values accepted by Config.ColorScheme.
const (
	ColorSchemeLight  = "light"
	ColorSchemeDark   = "dark"
	ColorSchemeSystem = "system"
)

type Config struct {
	Port                int                `json:"port"`
	Shell               string             `json:"shell"`
	ScrollbackLines     int                `json:"scrollback_lines"`
	RingBufferBytes     int                `json:"ring_buffer_bytes"`
	FontFamily          string             `json:"font_family"`
	FontSize            int                `json:"font_size"`
	SidebarWidth        int                `json:"sidebar_width"`
	ColorScheme         string             `json:"color_scheme"`
	Notification        NotificationConfig `json:"notification"`
	State               StateConfig        `json:"state"`
	Restore             RestoreConfig      `json:"restore"`
	ConfirmCloseRunning bool               `json:"confirm_close_running"`
	CopyOnSelect        bool               `json:"copy_on_select"`
	QuitWhenNoTabs      bool               `json:"quit_when_no_tabs"`
	CloseTabOnCleanExit bool               `json:"close_tab_on_clean_exit"`
	ShiftEnterNewline   bool               `json:"shift_enter_newline"`
	KeyBindings         KeyBindingsConfig  `json:"key_bindings"`
	AuthToken           string             `json:"auth_token"`
}

func Defaults() Config {
	return Config{
		Port:            8642,
		Shell:           "/bin/zsh",
		ScrollbackLines: 10000,
		RingBufferBytes: 5 * 1024 * 1024,
		FontFamily:      "Menlo, Monaco, 'Courier New', monospace",
		FontSize:        14,
		SidebarWidth:    240,
		ColorScheme:     ColorSchemeSystem,
		Notification: NotificationConfig{
			Enabled:       true,
			Always:        false,
			MinDurationMs: 0,
			Sound:         false,
			Commands:      DefaultNotifyCommands(),
		},
		State: StateConfig{
			Enabled:         true,
			DebounceMs:      120,
			QuiescenceMs:    1500,
			BottomLines:     15,
			NotifyOnBlocked: true,
			NotifyOnIdle:    false,
			ManifestDir:     "",
		},
		Restore: RestoreConfig{
			Enabled:     true,
			Commands:    map[string]string{},
			MaxSessions: 8,
			MaxAgeHours: 72,
		},
		ConfirmCloseRunning: true,
		CopyOnSelect:        false,
		QuitWhenNoTabs:      true,
		CloseTabOnCleanExit: true,
		ShiftEnterNewline:   true,
		KeyBindings: KeyBindingsConfig{
			Enabled:       false,
			Prefix:        "ctrl+j",
			NextTab:       "n",
			PrevTab:       "p",
			ToggleSidebar: "j",
		},
	}
}

type Store struct {
	mu   sync.RWMutex
	cfg  Config
	path string
}

func LoadOrCreate() (*Store, error) {
	path, err := paths.ConfigPath()
	if err != nil {
		return nil, err
	}
	support, err := paths.SupportDir()
	if err != nil {
		return nil, err
	}
	if err := paths.EnsureDir(support); err != nil {
		return nil, err
	}

	s := &Store{path: path, cfg: Defaults()}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		token, err := randomToken()
		if err != nil {
			return nil, err
		}
		s.cfg.AuthToken = token
		if err := s.saveLocked(); err != nil {
			return nil, err
		}
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &s.cfg); err != nil {
		return nil, err
	}
	if s.cfg.AuthToken == "" {
		token, err := randomToken()
		if err != nil {
			return nil, err
		}
		s.cfg.AuthToken = token
		if err := s.saveLocked(); err != nil {
			return nil, err
		}
	}
	s.applyDefaults()
	return s, nil
}

func (s *Store) applyDefaults() {
	d := Defaults()
	if s.cfg.Port == 0 {
		s.cfg.Port = d.Port
	}
	if s.cfg.Shell == "" {
		s.cfg.Shell = d.Shell
	}
	if s.cfg.ScrollbackLines == 0 {
		s.cfg.ScrollbackLines = d.ScrollbackLines
	}
	if s.cfg.RingBufferBytes == 0 {
		s.cfg.RingBufferBytes = d.RingBufferBytes
	}
	if s.cfg.FontFamily == "" {
		s.cfg.FontFamily = d.FontFamily
	}
	if s.cfg.FontSize == 0 {
		s.cfg.FontSize = d.FontSize
	}
	if s.cfg.SidebarWidth == 0 {
		s.cfg.SidebarWidth = d.SidebarWidth
	}
	switch s.cfg.ColorScheme {
	case ColorSchemeLight, ColorSchemeDark, ColorSchemeSystem:
	default:
		s.cfg.ColorScheme = d.ColorScheme
	}
	if s.cfg.KeyBindings.Prefix == "" {
		s.cfg.KeyBindings.Prefix = d.KeyBindings.Prefix
	}
	if s.cfg.KeyBindings.NextTab == "" {
		s.cfg.KeyBindings.NextTab = d.KeyBindings.NextTab
	}
	if s.cfg.KeyBindings.PrevTab == "" {
		s.cfg.KeyBindings.PrevTab = d.KeyBindings.PrevTab
	}
	if s.cfg.KeyBindings.ToggleSidebar == "" {
		s.cfg.KeyBindings.ToggleSidebar = d.KeyBindings.ToggleSidebar
	}
	if s.cfg.State.DebounceMs == 0 {
		s.cfg.State.DebounceMs = d.State.DebounceMs
	}
	if s.cfg.State.BottomLines == 0 {
		s.cfg.State.BottomLines = d.State.BottomLines
	}
	// state.notify_on_idle needs no fill-in: its default is false, which is
	// also what a missing key unmarshals to, so an older config lands on the
	// default and an explicit true survives untouched.

	if s.cfg.Restore.MaxSessions == 0 {
		s.cfg.Restore.MaxSessions = d.Restore.MaxSessions
	}
	if s.cfg.Restore.Commands == nil {
		s.cfg.Restore.Commands = map[string]string{}
	}
	// restore.enabled and restore.max_age_hours need no fill-in. Unmarshalling
	// over Defaults() leaves a missing key at its default, so an absent key
	// lands on true / 72 while an explicit false / 0 survives — and 0 is a
	// meaningful age, not "unset".

	// A missing key unmarshals to nil, while an explicit [] unmarshals to an
	// empty non-nil slice. Only the former gets the default list.
	if s.cfg.Notification.Commands == nil {
		s.cfg.Notification.Commands = d.Notification.Commands
	} else {
		for i, name := range s.cfg.Notification.Commands {
			s.cfg.Notification.Commands[i] = strings.TrimSpace(name)
		}
	}
}

// clone returns a Config whose slice fields do not share storage with the
// receiver, so callers and json.Unmarshal cannot write through into it.
func (c Config) clone() Config {
	if c.Notification.Commands != nil {
		c.Notification.Commands = append([]string(nil), c.Notification.Commands...)
	}
	if c.Restore.Commands != nil {
		commands := make(map[string]string, len(c.Restore.Commands))
		for agent, command := range c.Restore.Commands {
			commands[agent] = command
		}
		c.Restore.Commands = commands
	}
	return c
}

func (s *Store) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg.clone()
}

func (s *Store) Public() Config {
	c := s.Get()
	c.AuthToken = ""
	return c
}

func (s *Store) AuthToken() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg.AuthToken
}

func (s *Store) Patch(patch map[string]any) (Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	cleanPatch := make(map[string]any, len(patch))
	for key, value := range patch {
		if key != "auth_token" {
			cleanPatch[key] = value
		}
	}
	updated, err := json.Marshal(cleanPatch)
	if err != nil {
		return Config{}, err
	}
	next := s.cfg.clone()
	if err := json.Unmarshal(updated, &next); err != nil {
		return Config{}, err
	}
	next.AuthToken = s.cfg.AuthToken
	if err := validate(next); err != nil {
		return Config{}, err
	}
	s.cfg = next
	s.applyDefaults()
	if err := s.saveLocked(); err != nil {
		return Config{}, err
	}
	out := s.cfg.clone()
	out.AuthToken = ""
	return out, nil
}

func validate(cfg Config) error {
	if !filepath.IsAbs(cfg.Shell) {
		return fmt.Errorf("shell must be an absolute path")
	}
	info, err := os.Stat(cfg.Shell)
	if err != nil {
		return fmt.Errorf("shell: %w", err)
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("shell is not executable")
	}
	if cfg.Port < 1 || cfg.Port > 65535 {
		return fmt.Errorf("port must be between 1 and 65535")
	}
	if cfg.RingBufferBytes <= 0 {
		return fmt.Errorf("ring_buffer_bytes must be positive")
	}
	if cfg.ScrollbackLines <= 0 {
		return fmt.Errorf("scrollback_lines must be positive")
	}
	if cfg.FontSize <= 0 {
		return fmt.Errorf("font_size must be positive")
	}
	if cfg.SidebarWidth <= 0 {
		return fmt.Errorf("sidebar_width must be positive")
	}
	switch cfg.ColorScheme {
	case ColorSchemeLight, ColorSchemeDark, ColorSchemeSystem:
	default:
		return fmt.Errorf("color_scheme must be one of %q, %q, %q", ColorSchemeLight, ColorSchemeDark, ColorSchemeSystem)
	}
	if cfg.Notification.MinDurationMs < 0 {
		return fmt.Errorf("notification.min_duration_ms must be non-negative")
	}
	for _, name := range cfg.Notification.Commands {
		if strings.TrimSpace(name) == "" {
			return fmt.Errorf("notification.commands entries must not be blank")
		}
	}
	if err := validateKeyBindings(cfg.KeyBindings); err != nil {
		return err
	}
	if err := validateState(cfg.State); err != nil {
		return err
	}
	if err := validateRestore(cfg.Restore); err != nil {
		return err
	}
	return nil
}

// MaxResumeCommandLen bounds a resume command, which is typed into a live
// shell; the limit keeps a stray value from becoming a huge injected line.
const MaxResumeCommandLen = 512

func validateRestore(r RestoreConfig) error {
	if r.MaxSessions < 1 || r.MaxSessions > 32 {
		return fmt.Errorf("restore.max_sessions must be between 1 and 32")
	}
	if r.MaxAgeHours < 0 {
		return fmt.Errorf("restore.max_age_hours must be non-negative")
	}
	for agent, command := range r.Commands {
		if strings.TrimSpace(agent) == "" {
			return fmt.Errorf("restore.commands keys must not be blank")
		}
		// An empty command is how a user disables one agent, so only the
		// shape of a non-empty command is checked here.
		if strings.ContainsAny(command, "\r\n") {
			return fmt.Errorf("restore.commands[%s] must not contain a line break", agent)
		}
		if len(command) > MaxResumeCommandLen {
			return fmt.Errorf("restore.commands[%s] must be at most %d characters", agent, MaxResumeCommandLen)
		}
	}
	return nil
}

func validateState(s StateConfig) error {
	if s.DebounceMs < 20 || s.DebounceMs > 5000 {
		return fmt.Errorf("state.debounce_ms must be between 20 and 5000")
	}
	if s.QuiescenceMs < 0 || s.QuiescenceMs > 60000 {
		return fmt.Errorf("state.quiescence_ms must be between 0 and 60000")
	}
	if s.BottomLines < 1 || s.BottomLines > 200 {
		return fmt.Errorf("state.bottom_lines must be between 1 and 200")
	}
	if s.ManifestDir != "" && !filepath.IsAbs(s.ManifestDir) {
		return fmt.Errorf("state.manifest_dir must be empty or an absolute path")
	}
	return nil
}

var reservedPrefixes = map[string]struct{}{
	"meta+1": {}, "meta+2": {}, "meta+3": {}, "meta+4": {}, "meta+5": {},
	"meta+6": {}, "meta+7": {}, "meta+8": {}, "meta+9": {},
	"meta+n": {}, "meta+c": {}, "meta+v": {},
}

var modifierOrder = []string{"ctrl", "alt", "shift", "meta"}

func parseBinding(spec string) (mods []string, key string, ok bool) {
	if spec == "" || spec != strings.ToLower(spec) {
		return nil, "", false
	}
	parts := strings.Split(spec, "+")
	for _, part := range parts {
		if part == "" {
			return nil, "", false
		}
	}
	key = parts[len(parts)-1]
	mods = parts[:len(parts)-1]
	last := -1
	seen := make(map[string]struct{}, len(mods))
	for _, mod := range mods {
		idx := -1
		for i, name := range modifierOrder {
			if mod == name {
				idx = i
				break
			}
		}
		if idx < 0 {
			return nil, "", false
		}
		if _, dup := seen[mod]; dup {
			return nil, "", false
		}
		if idx <= last {
			return nil, "", false
		}
		seen[mod] = struct{}{}
		last = idx
	}
	for _, name := range modifierOrder {
		if key == name {
			return nil, "", false
		}
	}
	return mods, key, true
}

func validateKeyBindings(kb KeyBindingsConfig) error {
	type slot struct {
		name string
		spec string
	}
	for _, s := range []slot{
		{name: "prefix", spec: kb.Prefix},
		{name: "next_tab", spec: kb.NextTab},
		{name: "prev_tab", spec: kb.PrevTab},
		{name: "toggle_sidebar", spec: kb.ToggleSidebar},
	} {
		mods, key, ok := parseBinding(s.spec)
		if !ok {
			return fmt.Errorf("key_bindings.%s is invalid", s.name)
		}
		if key == "escape" {
			return fmt.Errorf("key_bindings must not use escape")
		}
		if s.name == "prefix" && len(mods) == 0 {
			return fmt.Errorf("key_bindings.prefix must include a modifier")
		}
	}
	if kb.NextTab == kb.PrevTab || kb.NextTab == kb.ToggleSidebar || kb.PrevTab == kb.ToggleSidebar {
		return fmt.Errorf("key_bindings.next_tab, prev_tab, and toggle_sidebar must differ")
	}
	if _, hit := reservedPrefixes[kb.Prefix]; hit {
		return fmt.Errorf("key_bindings.prefix conflicts with an existing shortcut")
	}
	return nil
}

func (s *Store) saveLocked() error {
	data, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, append(data, '\n'), 0o600)
}

func (c Config) ResolvedTheme() string {
	switch c.ColorScheme {
	case ColorSchemeLight, ColorSchemeDark:
		return c.ColorScheme
	default:
		return systemAppearance()
	}
}

var systemAppearance = macOSAppearance

func macOSAppearance() string {
	out, err := exec.Command("defaults", "read", "-g", "AppleInterfaceStyle").Output()
	if err == nil && strings.EqualFold(strings.TrimSpace(string(out)), "Dark") {
		return ColorSchemeDark
	}
	return ColorSchemeLight
}

func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
