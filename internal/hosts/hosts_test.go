package hosts

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/isucon2026/isukit/internal/config"
)

func write(t *testing.T, dir, name, body string) {
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPreRolesLayout(t *testing.T) {
	s, err := Load(t.TempDir(), config.Values{"APP": "isu1", "EXTRA_HOSTS": " isu2  isu3 "})
	if err != nil {
		t.Fatal(err)
	}
	if s.FromFile {
		t.Error("no hosts file: FromFile must be false")
	}
	var app []string
	for _, h := range s.With("app") {
		app = append(app, h.Target)
	}
	if !reflect.DeepEqual(app, []string{"isu1", "isu2", "isu3"}) {
		t.Errorf("app hosts %v", app)
	}
	if got := s.With("db"); len(got) != 1 || got[0].Target != "isu1" {
		t.Errorf("db hosts %v", got)
	}
}

func TestRolesFileAndFacts(t *testing.T) {
	dir := t.TempDir()
	write(t, dir, "hosts", "# comment\nisu1 web,app\n\nisu2\nisu3 db\n")
	write(t, dir, "manifest", "WEB_SERVER=nginx\nDB_SERVER=''\n")
	write(t, dir, "manifest.isu1", "WEB_SERVER=nginx\nDB_SERVER=''\n")
	write(t, dir, "manifest.isu3", "DB_SERVER=mysql\n")
	s, err := Load(dir, config.Values{"APP": "isu1"})
	if err != nil {
		t.Fatal(err)
	}
	if !s.List[1].Has("app") {
		t.Error("a host with no roles column is an app host")
	}
	if got := s.Units(s.List[0], "isu-go.service", ""); !reflect.DeepEqual(got, []string{"nginx", "isu-go.service"}) {
		t.Errorf("isu1 units %v (roles order: web first)", got)
	}
	if got := s.Units(s.List[2], "isu-go.service", ""); !reflect.DeepEqual(got, []string{"mysql"}) {
		t.Errorf("db host units %v — its own manifest must win over the probed host's empty DB_SERVER", got)
	}
	os.Remove(filepath.Join(dir, "manifest.isu3"))
	write(t, dir, "manifest.isu2", "DB_SERVER=mysql\n")
	if got := s.Fact("isu3", "DB_SERVER"); got != "mysql" {
		t.Errorf("unprobed db host: any host's report, got %q", got)
	}
}
