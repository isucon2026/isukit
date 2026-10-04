// Package app holds what a command needs, built once and passed in: the
// config, the probed manifest, the hosts and how to reach them. It replaces
// the bash side's globals and `load` (which re-sources everything, and is
// re-pointed at another host through HOST_OVERRIDE in a subshell).
package app

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/isucon2026/isukit/internal/config"
	"github.com/isucon2026/isukit/internal/hosts"
	"github.com/isucon2026/isukit/internal/runner"
)

// State is the per-contest dir inside the problem repo.
const State = ".isukit"

// App is one invocation's view of the world.
type App struct {
	Dir      string // the problem repo (the working dir)
	Config   config.Values
	Manifest config.Values // the probed host's; empty before the first probe
	Hosts    *hosts.Set
	Runner   runner.Runner
	Out, Err io.Writer
}

// Load reads <dir>/.isukit the way `load` does; no config is the same error.
func Load(dir string, out, errw io.Writer) (*App, error) {
	state := filepath.Join(dir, State)
	cfg, err := config.ReadFile(filepath.Join(state, "config"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no %s/config here. cd into the problem repo, or run: isukit init <repo-url>", State)
		}
		return nil, err
	}
	man, err := config.ReadFile(filepath.Join(state, "manifest"))
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if man == nil {
		man = config.Values{}
	}
	hs, err := hosts.Load(state, cfg)
	if err != nil {
		return nil, err
	}
	return &App{
		Dir: dir, Config: cfg, Manifest: man, Hosts: hs,
		Runner: runner.SSH{Opts: strings.Fields(cfg.Get("SSH_OPTS"))},
		Out:    out, Err: errw,
	}, nil
}

// Get reads a value the way the bash side sees it after `load`: the manifest
// sourced after the config, so a manifest value wins.
func (a *App) Get(key string) string {
	if v, ok := a.Manifest[key]; ok {
		return v
	}
	return a.Config.Get(key)
}

// Say, Warn and Fail print like lib/core.sh's say / warn / die.
func (a *App) Say(format string, args ...any) {
	fmt.Fprintf(a.Err, "\033[36m:: %s\033[0m\n", fmt.Sprintf(format, args...))
}
func (a *App) Warn(format string, args ...any) {
	fmt.Fprintf(a.Err, "\033[33m~~ %s\033[0m\n", fmt.Sprintf(format, args...))
}
