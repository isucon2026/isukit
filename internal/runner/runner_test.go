package runner

import (
	"context"
	"strings"
	"testing"
)

func TestScriptFramesLikeRshStdin(t *testing.T) {
	rec := &Recorder{}
	if _, err := Script(context.Background(), rec, "isu3", "os.sh", Var{"CHECK_UNITS", "mysql isu-go.service"}, Var{"X", "it's"}); err != nil {
		t.Fatal(err)
	}
	if len(rec.Calls) != 1 {
		t.Fatalf("%d calls", len(rec.Calls))
	}
	c := rec.Calls[0]
	if c.Host != "isu3" || c.Command != "bash -s" {
		t.Errorf("call %q %q", c.Host, c.Command)
	}
	lines := strings.SplitN(c.Stdin, "\n", 3)
	if lines[0] != "CHECK_UNITS='mysql isu-go.service'" || lines[1] != `X='it'\''s'` {
		t.Errorf("vars %q", lines[:2])
	}
	if !strings.HasPrefix(lines[2], "#!/bin/bash") {
		t.Errorf("script must follow the vars: %q", lines[2][:20])
	}
}

func TestScriptUnknown(t *testing.T) {
	if _, err := Script(context.Background(), &Recorder{}, "h", "nope.sh"); err == nil {
		t.Error("want an error for a script that is not embedded")
	}
}
