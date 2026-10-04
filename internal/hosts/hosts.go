// Package hosts is the Go side of lib/hosts.sh: which hosts there are, which
// roles each holds, and what each one's probe reported.
//
// isukit.hosts (repo root, committed so the team shares it) has one
// "<ssh-target> <role,role...>" per line; an older .isukit/hosts is read while
// it is the only one. Without either, the pre-roles layout holds: the probed
// host ($APP) does web, app and db, and every EXTRA_HOSTS entry is an app host.
package hosts

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/isucon2026/isukit/internal/config"
)

// Known lists the roles a host can hold.
var Known = []string{"app", "web", "db"}

// Host is one machine and the roles it holds, in the order they were written.
type Host struct {
	Target string
	Roles  []string
}

// Has reports whether the host holds role.
func (h Host) Has(role string) bool {
	for _, r := range h.Roles {
		if r == role {
			return true
		}
	}
	return false
}

// Set is every host, in file order, plus where their manifests live.
type Set struct {
	State   string // the .isukit dir
	Primary string // $APP: the host probe reads .isukit/manifest from
	List    []Host
	// FromFile is false for the implied pre-roles layout.
	FromFile bool
	// File is the roles file as the bash side names it (relative to the repo).
	File string
}

// SharedFile is the committed roles file at the repo root.
const SharedFile = "isukit.hosts"

// Load reads the roles file under dir (the repo) — isukit.hosts, else a
// lone <state>/hosts — or derives the pre-roles layout from the config.
func Load(dir, state string, cfg config.Values) (*Set, error) {
	s := &Set{State: state, Primary: cfg.Get("APP"), File: SharedFile}
	path := filepath.Join(dir, SharedFile)
	legacy := filepath.Join(state, "hosts")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if _, err := os.Stat(legacy); err == nil {
			path = legacy
			if rel, err := filepath.Rel(dir, legacy); err == nil {
				s.File = rel
			}
		}
	}
	f, err := os.Open(path)
	switch {
	case err == nil:
		defer f.Close()
		s.FromFile = true
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || line[0] == '#' {
				continue
			}
			fields := strings.Fields(line)
			roles := "app"
			if len(fields) > 1 {
				roles = fields[1]
			}
			s.List = append(s.List, Host{Target: fields[0], Roles: strings.Split(roles, ",")})
		}
		return s, sc.Err()
	case os.IsNotExist(err):
		s.List = append(s.List, Host{Target: s.Primary, Roles: []string{"web", "app", "db"}})
		// unquoted ${EXTRA_HOSTS} in bash: split on whitespace, nothing else
		for _, h := range strings.Fields(cfg.Get("EXTRA_HOSTS")) {
			s.List = append(s.List, Host{Target: h, Roles: []string{"app"}})
		}
		return s, nil
	default:
		return nil, err
	}
}

// With returns the hosts holding any of roles, in order.
func (s *Set) With(roles ...string) []Host {
	var out []Host
	for _, h := range s.List {
		for _, r := range roles {
			if h.Has(r) {
				out = append(out, h)
				break
			}
		}
	}
	return out
}

// Has reports whether target is listed.
func (s *Set) Has(target string) bool {
	for _, h := range s.List {
		if h.Target == target {
			return true
		}
	}
	return false
}

// ManifestPath is where probe saves target's manifest.
func (s *Set) ManifestPath(target string) string {
	return filepath.Join(s.State, "manifest."+strings.ReplaceAll(target, "/", "_"))
}

// Fact is that host's probed value for key; else the first any host reported.
// The fleet runs one web server and one datastore kind, but only the hosts
// still running them report them: after mysql is stopped on the probed host,
// its own manifest says DB_SERVER=”, which must not erase the db host's.
func (s *Set) Fact(target, key string) string {
	if v := read(s.ManifestPath(target)).Get(key); v != "" {
		return v
	}
	others, _ := filepath.Glob(filepath.Join(s.State, "manifest.*"))
	sort.Strings(others)
	for _, f := range append([]string{filepath.Join(s.State, "manifest")}, others...) {
		if v := read(f).Get(key); v != "" {
			return v
		}
	}
	return ""
}

// Units are what host must be running, from its roles: the app unit (+ any
// extra units) for app, the web server for web, the datastore for db.
func (s *Set) Units(h Host, appUnit, extraUnits string) []string {
	var words []string
	for _, r := range h.Roles {
		switch r {
		case "app":
			words = append(words, strings.Fields(appUnit+" "+extraUnits)...)
		case "web":
			words = append(words, strings.Fields(s.Fact(h.Target, "WEB_SERVER"))...)
		case "db":
			words = append(words, strings.Fields(s.Fact(h.Target, "DB_SERVER"))...)
		}
	}
	seen := map[string]bool{}
	var out []string
	for _, w := range words {
		if !seen[w] {
			seen[w] = true
			out = append(out, w)
		}
	}
	return out
}

func read(path string) config.Values {
	v, err := config.ReadFile(path)
	if err != nil {
		return config.Values{}
	}
	return v
}
