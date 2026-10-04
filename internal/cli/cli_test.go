package cli

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/isucon2026/isukit/internal/app"
)

func repoRoot(t *testing.T) string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

// state writes a .isukit dir into a temp problem repo and returns its path.
func state(t *testing.T, files map[string]string) string {
	dir := t.TempDir()
	for name, body := range files {
		p := filepath.Join(dir, ".isukit", name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// TestHostsMatchesBash holds the ported `hosts` to the bash original:
// identical stdout and stderr for the same .isukit, in every layout.
func TestHostsMatchesBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	cfg := "APP=isu1\nBENCH=local\nEXTRA_UNITS=''\nEXTRA_HOSTS='isu2 isu3'\n"
	man := "APP_UNIT=isu-go.service\nWEB_SERVER=nginx\nDB_SERVER=mysql\n"
	cases := map[string]map[string]string{
		"pre-roles layout": {"config": cfg, "manifest": man},
		"roles file": {"config": cfg, "manifest": man,
			"hosts": "# <ssh-target> <roles>\nisu1 web,app\nisu2 app\nisu3 db\n"},
		"db fact from the db host's own manifest": {
			"config": cfg, "manifest": "APP_UNIT=isu-go.service\nWEB_SERVER=nginx\nDB_SERVER=''\n",
			"manifest.isu3": "DB_SERVER=mysql\n", "hosts": "isu1 web,app\nisu2 app\nisu3 db\n"},
		"no app host, probed host unlisted": {"config": cfg, "manifest": man, "hosts": "isu7 db\n"},
		"extra units, no manifest yet":      {"config": "APP=isu1\nEXTRA_UNITS='mock.service  matcher.service'\n"},
	}
	root := repoRoot(t)
	for name, files := range cases {
		t.Run(name, func(t *testing.T) {
			dir := state(t, files)
			var bout, berr bytes.Buffer
			cmd := exec.Command("bash", filepath.Join(root, "isukit"), "hosts")
			cmd.Dir, cmd.Stdout, cmd.Stderr = dir, &bout, &berr
			if err := cmd.Run(); err != nil {
				t.Fatalf("bash hosts: %v\n%s", err, berr.String())
			}
			var gout, gerr bytes.Buffer
			a, err := app.Load(dir, &gout, &gerr)
			if err != nil {
				t.Fatal(err)
			}
			if err := listHosts(a); err != nil {
				t.Fatal(err)
			}
			if gout.String() != bout.String() {
				t.Errorf("stdout differs\n--- bash\n%s--- go\n%s", bout.String(), gout.String())
			}
			if gerr.String() != berr.String() {
				t.Errorf("stderr differs\n--- bash\n%q\n--- go\n%q", berr.String(), gerr.String())
			}
		})
	}
}

func TestPassthroughKeepsExitCodes(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	t.Chdir(t.TempDir())
	var out, errw bytes.Buffer
	if code := run([]string{"no-such-command"}, &out, &errw); code != 1 {
		t.Errorf("unknown command: exit %d, want 1 (bash prints usage and exits 1)", code)
	}
	if code := run([]string{"score"}, &out, &errw); code != 1 {
		t.Errorf("score without .isukit: exit %d, want 1", code)
	}
}

func TestVersion(t *testing.T) {
	var out, errw bytes.Buffer
	if code := run([]string{"version"}, &out, &errw); code != 0 {
		t.Fatalf("exit %d: %s", code, errw.String())
	}
	if !strings.HasPrefix(out.String(), "isukit "+kitVersion()+" (") {
		t.Errorf("version line %q", out.String())
	}
}

func TestEveryBashCommandIsRouted(t *testing.T) {
	// every command bash's main() dispatches must be either passthrough or native
	b, err := os.ReadFile(filepath.Join(repoRoot(t), "isukit"))
	if err != nil {
		t.Fatal(err)
	}
	native := map[string]bool{"version": true, "hosts": true}
	routed := map[string]bool{}
	for _, n := range Passthrough {
		routed[n] = true
	}
	inMain := false
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "main()") {
			inMain = true
		}
		if !inMain {
			continue
		}
		l := strings.TrimSpace(line)
		i := strings.Index(l, ")")
		if i <= 0 || !strings.Contains(l, "cmd_") {
			continue
		}
		for _, name := range strings.Split(l[:i], "|") {
			if strings.HasPrefix(name, "-") {
				continue
			}
			if !routed[name] && !native[name] {
				t.Errorf("bash command %q is neither passthrough nor native", name)
			}
		}
	}
}
