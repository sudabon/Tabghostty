package agentfixtures

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

// RelRoot is the repository-relative fixture tree.
const RelRoot = "tests/fixtures/agents"

// RepoRoot walks from this source file to the module root (directory with go.mod).
func RepoRoot() (string, error) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return "", fmt.Errorf("agentfixtures: cannot locate source file")
	}
	dir := filepath.Dir(file)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("agentfixtures: go.mod not found from %s", file)
		}
		dir = parent
	}
}

// Root returns tests/fixtures/agents under the module root.
func Root() (string, error) {
	repo, err := RepoRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(repo, RelRoot), nil
}
