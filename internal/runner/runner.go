// Package runner is how isukit reaches a host: the Go side of rsh / rsh_stdin
// in lib/core.sh. Commands take a Runner, so tests hand them a Recorder.
package runner

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"

	"github.com/isucon2026/isukit"
)

// Runner runs a command on a host. host "local" means this machine.
type Runner interface {
	// Run executes command (a shell command line) on host, feeding it stdin.
	Run(ctx context.Context, host, command string, stdin io.Reader) ([]byte, error)
}

// SSH reaches hosts with ssh, as the bash side does; Opts is SSH_OPTS split on
// whitespace (bash expands it unquoted, so no shell quoting applies).
type SSH struct{ Opts []string }

func (s SSH) Run(ctx context.Context, host, command string, stdin io.Reader) ([]byte, error) {
	var cmd *exec.Cmd
	if host == "local" {
		cmd = exec.CommandContext(ctx, "bash", "-lc", command)
	} else {
		args := append(append([]string{}, s.Opts...), "-o", "StrictHostKeyChecking=accept-new", host, command)
		cmd = exec.CommandContext(ctx, "ssh", args...)
	}
	cmd.Stdin = stdin
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.Bytes(), fmt.Errorf("%s: %w: %s", host, err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// Var is one VAR=value line prepended to a remote script.
type Var struct{ Name, Value string }

// Script runs remote/<name> on host the way rsh_stdin does: `bash -s` with
// the VAR=value lines (shell-quoted) ahead of the script on stdin.
func Script(ctx context.Context, r Runner, host, name string, vars ...Var) ([]byte, error) {
	body, err := isukit.Kit.ReadFile("remote/" + name)
	if err != nil {
		return nil, err
	}
	var in bytes.Buffer
	for _, v := range vars {
		fmt.Fprintf(&in, "%s=%s\n", v.Name, Quote(v.Value))
	}
	in.Write(body)
	return r.Run(ctx, host, "bash -s", &in)
}

// Quote makes s a single shell word.
func Quote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// Recorder is a Runner for tests: it records every call and answers from Reply.
type Recorder struct {
	Calls []Call
	Reply func(host, command string, stdin string) ([]byte, error)
}

// Call is one recorded Run.
type Call struct{ Host, Command, Stdin string }

func (r *Recorder) Run(_ context.Context, host, command string, stdin io.Reader) ([]byte, error) {
	var in string
	if stdin != nil {
		b, _ := io.ReadAll(stdin)
		in = string(b)
	}
	r.Calls = append(r.Calls, Call{host, command, in})
	if r.Reply == nil {
		return nil, nil
	}
	return r.Reply(host, command, in)
}
