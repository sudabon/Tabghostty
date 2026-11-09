package agentdetect

import "embed"

//go:embed manifests/*.json
var bundledFS embed.FS
