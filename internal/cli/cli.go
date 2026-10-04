// Package cli is isukit's command line. Commands move from bash to Go one at
// a time: a command is either native (a cobra command with a Go RunE) or
// passed through, argv untouched, to the embedded bash kit, which still owns
// everything not ported yet — including the usage text, `help`, no-argument
// and unknown-command behaviour, so the CLI looks the same as before.
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/isucon2026/isukit/internal/shell"
)

// Passthrough lists every command the bash kit still implements; each is
// registered so `isukit <cmd> ...` reaches bash with its argv as given.
var Passthrough = []string{
	"go", "init", "host", "probe", "benchprobe", "benchcmd", "benchmode", "unit",
	"setup", "logs", "etc", "bench", "score", "show", "alp", "slow", "pprof", "os",
	"doctor", "attribute", "ship", "revert", "deploy", "restart", "final", "finalize",
}

type exitCode int

func (e exitCode) Error() string { return fmt.Sprintf("exit %d", int(e)) }

// Execute runs one invocation and returns the process exit code.
func Execute(args []string) int {
	return run(args, os.Stdout, os.Stderr)
}

func run(args []string, out, errw io.Writer) int {
	root := newRoot(out, errw)
	root.SetArgs(args)
	err := root.Execute()
	var code exitCode
	switch {
	case err == nil:
		return 0
	case errors.As(err, &code):
		return int(code)
	default:
		fmt.Fprintf(errw, "\033[31m!! %s\033[0m\n", err)
		return 1
	}
}

func newRoot(out, errw io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:   "isukit",
		Short: "repo-agnostic ISUCON bootstrap + measurement loop",
		// no command, an unknown one, -h / --help: all bash's, as before
		DisableFlagParsing: true,
		Args:               cobra.ArbitraryArgs,
		RunE:               bash,
		SilenceErrors:      true,
		SilenceUsage:       true,
	}
	root.SetOut(out)
	root.SetErr(errw)
	root.CompletionOptions.DisableDefaultCmd = true
	root.SetHelpCommand(&cobra.Command{Use: "help", Hidden: true, DisableFlagParsing: true,
		RunE: func(c *cobra.Command, a []string) error { return bash(c, append([]string{"help"}, a...)) }})
	for _, name := range Passthrough {
		name := name
		root.AddCommand(&cobra.Command{
			Use:                name,
			DisableFlagParsing: true,
			RunE: func(c *cobra.Command, a []string) error {
				return bash(c, append([]string{name}, a...))
			},
		})
	}
	root.AddCommand(versionCmd(), hostsCmd())
	return root
}

// bash hands argv to the embedded bash kit and carries its exit code back.
func bash(_ *cobra.Command, args []string) error {
	code, err := shell.Run(args)
	if err != nil {
		return err
	}
	if code != 0 {
		return exitCode(code)
	}
	return nil
}
