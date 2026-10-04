package shell

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDirUnpacksTheKit(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	d1, err := Dir()
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"isukit", "lib/core.sh", "lib/final.sh", "remote/probe.sh"} {
		if _, err := os.Stat(filepath.Join(d1, f)); err != nil {
			t.Errorf("missing %s: %v", f, err)
		}
	}
	d2, err := Dir()
	if err != nil || d2 != d1 {
		t.Errorf("second call: %q %v, want the same dir", d2, err)
	}
}
