// Package web holds the browser UI, embedded into the binary.
package web

import "embed"

// Files is the UI: index.html, app.js, style.css.
//
//go:embed index.html app.js style.css
var Files embed.FS
