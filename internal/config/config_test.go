package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func TestParseForms(t *testing.T) {
	in := `# isukit config
APP=isukit-app          # ssh target
BENCH='local'
SSH_OPTS='-F .isukit/ssh_config -o X'
EXTRA_HOSTS=''
QUOTE='it'\''s'
DQ="a \"b\" \$c"
OS=Ubuntu\ 24.04.5\ LTS
ANSI=$'line1\nline2\ttab\x41\101'
  INDENTED=yes
not an assignment
9BAD=x
`
	v, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"APP": "isukit-app", "BENCH": "local", "SSH_OPTS": "-F .isukit/ssh_config -o X",
		"EXTRA_HOSTS": "", "QUOTE": "it's", "DQ": `a "b" $c`, "OS": "Ubuntu 24.04.5 LTS",
		"ANSI": "line1\nline2\ttabAA", "INDENTED": "yes",
	}
	for k, w := range want {
		if got, ok := v[k]; !ok || got != w {
			t.Errorf("%s = %q (set=%v), want %q", k, got, ok, w)
		}
	}
	if _, ok := v["9BAD"]; ok {
		t.Error("9BAD is not a valid name")
	}
}

// Every value bash's printf %q can produce must read back as what bash meant:
// round-trip awkward strings through real bash and compare.
func TestRoundTripThroughBash(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	vals := []string{"", "plain", "two words", "it's", `a "q" b`, "tab\there", "nl\nhere", "$HOME", "back\\slash", "ünïcode", "*glob?"}
	var script strings.Builder
	for i, s := range vals {
		script.WriteString("printf 'K" + string(rune('A'+i)) + "=%q\\n' " + shq(s) + "\n")
	}
	out, err := exec.Command("bash", "-c", script.String()).Output()
	if err != nil {
		t.Fatal(err)
	}
	v, err := Parse(strings.NewReader(string(out)))
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	for i, s := range vals {
		if got := v["K"+string(rune('A'+i))]; got != s {
			t.Errorf("%q came back as %q (bash wrote %s)", s, got, strings.Split(string(out), "\n")[i])
		}
	}
}

// The probe fixtures' expected files are real probe output: they must parse.
func TestFixtureManifests(t *testing.T) {
	files, _ := filepath.Glob("../../test/fixtures/*/expected")
	if len(files) == 0 {
		t.Skip("no fixtures")
	}
	sort.Strings(files)
	for _, f := range files {
		v, err := ReadFile(f)
		if err != nil {
			t.Errorf("%s: %v", f, err)
			continue
		}
		if len(v) == 0 {
			t.Errorf("%s: no values", f)
		}
	}
}

func shq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func TestReadFileMissing(t *testing.T) {
	if _, err := ReadFile(filepath.Join(t.TempDir(), "nope")); !os.IsNotExist(err) {
		t.Fatalf("want not-exist, got %v", err)
	}
}
