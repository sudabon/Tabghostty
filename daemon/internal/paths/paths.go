package paths

import (
	"os"
	"path/filepath"
)

const AppName = "WebTabinal"
const CLIName = "webtabinal"

func Home() (string, error) {
	return os.UserHomeDir()
}

func SupportDir() (string, error) {
	home, err := Home()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Application Support", AppName), nil
}

func ManifestsDir() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "manifests"), nil
}

// ImagesDir holds images pasted or dropped into a terminal. They live beside
// the other app data because an agent may re-read one when a session is
// resumed, which a system temp directory does not survive.
func ImagesDir() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "images"), nil
}

func LogsDir() (string, error) {
	home, err := Home()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Logs", AppName), nil
}

func ConfigPath() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

func IntegrationPath() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "integration.zsh"), nil
}

func ZshInjectDir() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "zsh-inject"), nil
}

// RestorePath is the agent-session restore snapshot. It holds operational
// state, not user-edited settings, which is why it sits beside config.json
// rather than inside it.
func RestorePath() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "restore.json"), nil
}

func BashIntegrationPath() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "integration.bash"), nil
}

func BashInjectDir() (string, error) {
	dir, err := SupportDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "bash-inject"), nil
}

func BashRcfile() (string, error) {
	dir, err := BashInjectDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "bashrc"), nil
}

func LogPath() (string, error) {
	dir, err := LogsDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "daemon.log"), nil
}

func StdioLogPath() (string, error) {
	dir, err := LogsDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "daemon.stdio.log"), nil
}

func EnsureDir(path string) error {
	return os.MkdirAll(path, 0o755)
}
