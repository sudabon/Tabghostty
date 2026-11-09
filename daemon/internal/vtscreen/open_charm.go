//go:build !ghostty

package vtscreen

// ModelName names the screen model this build uses.
const ModelName = "charmbracelet"

// LibraryVersion reports the linked libghostty-vt version; the default build links none.
func LibraryVersion() string {
	return ""
}

// Open constructs a screen with logging and geometry options.
// The default (pure Go) build uses charmbracelet/x/vt; build with -tags ghostty for libghostty-vt.
func Open(opts Options) (Screen, error) {
	return openCharm(opts)
}
