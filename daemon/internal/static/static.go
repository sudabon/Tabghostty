package static

import (
	"embed"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

//go:embed all:dist
var distEmbed embed.FS

//go:embed all:placeholder
var placeholderEmbed embed.FS

const placeholderMarker = "Frontend not built"

// IsPlaceholder reports whether dist still lacks a built frontend.
func IsPlaceholder() bool {
	b, err := distEmbed.ReadFile("dist/index.html")
	if err != nil {
		return true
	}
	return strings.Contains(string(b), placeholderMarker)
}

func contentFS() (fs.FS, error) {
	if IsPlaceholder() {
		return fs.Sub(placeholderEmbed, "placeholder")
	}
	return fs.Sub(distEmbed, "dist")
}

func Handler() http.Handler {
	sub, err := contentFS()
	if err != nil {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "frontend not embedded", http.StatusServiceUnavailable)
		})
	}
	fileServer := http.FileServer(http.FS(sub))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestPath := strings.TrimPrefix(r.URL.Path, "/")
		if requestPath == "" {
			requestPath = "index.html"
		}
		if _, err := fs.Stat(sub, requestPath); err != nil {
			if path.Ext(requestPath) != "" {
				http.NotFound(w, r)
				return
			}
			// SPA fallback
			r.URL.Path = "/"
			disableAppShellCache(w)
			fileServer.ServeHTTP(w, r)
			return
		}
		if isAppShell(requestPath) {
			disableAppShellCache(w)
		}
		fileServer.ServeHTTP(w, r)
	})
}

func isAppShell(requestPath string) bool {
	switch path.Base(requestPath) {
	case "index.html", "sw.js", "manifest.webmanifest":
		return true
	default:
		return false
	}
}

func disableAppShellCache(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-cache")
}

// DevHandler serves from web/dist on disk when present (optional helper).
func DevHandler(repoRoot string) http.Handler {
	dir := filepath.Join(repoRoot, "web", "dist")
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return nil
	}
	return http.FileServer(http.Dir(dir))
}
