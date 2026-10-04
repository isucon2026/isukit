// Package isukit carries the kit's shell code inside the Go binary.
//
// The bash entry point, the laptop-side lib/ and the host-side remote/
// scripts are embedded, so `go install github.com/isucon2026/isukit/cmd/isukit`
// is the whole install: commands not yet ported to Go run from this copy
// (see internal/shell), and remote/ scripts are shipped to hosts from it.
package isukit

import "embed"

// Kit holds isukit, lib/*.sh and remote/*.sh exactly as they are in the repo.
//
//go:embed isukit lib/*.sh remote/*.sh
var Kit embed.FS
