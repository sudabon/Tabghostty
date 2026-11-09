package launchd

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/sudabon/webtabinal/internal/paths"
)

const Label = "com.webtabinal.app"

func PlistPath() (string, error) {
	home, err := paths.Home()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", Label+".plist"), nil
}

func WritePlist(binPath string) error {
	path, err := PlistPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	logPath, err := paths.StdioLogPath()
	if err != nil {
		return err
	}
	content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>%s</string>
  <key>StandardErrorPath</key>
  <string>%s</string>
</dict>
</plist>
`, xmlEscape(Label), xmlEscape(binPath), xmlEscape(logPath), xmlEscape(logPath))
	return os.WriteFile(path, []byte(content), 0o644)
}

func xmlEscape(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

func Install(binPath string) error {
	if err := WritePlist(binPath); err != nil {
		return err
	}
	path, _ := PlistPath()
	_, _ = exec.Command("launchctl", "unload", path).CombinedOutput()
	out, err := exec.Command("launchctl", "load", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl load: %w: %s", err, out)
	}
	return nil
}

func Uninstall() error {
	path, err := PlistPath()
	if err != nil {
		return err
	}
	out, err := exec.Command("launchctl", "unload", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl unload: %w: %s", err, out)
	}
	return os.Remove(path)
}

func Status() (string, error) {
	out, err := exec.Command("launchctl", "list").Output()
	if err != nil {
		return "", err
	}
	if strings.Contains(string(out), Label) {
		return "loaded", nil
	}
	path, _ := PlistPath()
	if _, err := os.Stat(path); err == nil {
		return "installed-but-not-loaded", nil
	}
	return "not-installed", nil
}
