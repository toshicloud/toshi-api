// Package api holds the version of the Toshi API: the protos under proto/,
// and the Go and TypeScript generated from them.
package api

import (
	_ "embed"
	"strings"
)

//go:embed VERSION
var version string

// Version is the API's version, MAJOR.MINOR.PATCH, as VERSION holds it.
func Version() string { return strings.TrimSpace(version) }
