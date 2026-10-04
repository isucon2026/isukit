package cli

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/isucon2026/isukit/internal/app"
)

// hosts is cmd_hosts from lib/hosts.sh, ported: same lines, same warnings.
// TestHostsMatchesBash holds the two to identical output.
func hostsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "hosts",
		Short: "hosts, their roles, and the units each must run",
		Args:  cobra.ArbitraryArgs, // bash ignored extra args; so do we
		RunE: func(c *cobra.Command, _ []string) error {
			dir, err := os.Getwd()
			if err != nil {
				return err
			}
			a, err := app.Load(dir, c.OutOrStdout(), c.ErrOrStderr())
			if err != nil {
				return err
			}
			return listHosts(a)
		},
	}
}

func listHosts(a *app.App) error {
	hs := a.Hosts
	if !hs.FromFile {
		a.Say("no %s — pre-roles layout (%s does everything). set roles: isukit host role <target> <roles>", hs.File, hs.Primary)
	}
	for _, h := range hs.List {
		units := strings.Join(hs.Units(h, a.Get("APP_UNIT"), a.Get("EXTRA_UNITS")), " ")
		if units == "" {
			units = "?"
		}
		mark := ""
		if h.Target == hs.Primary {
			mark = "   (probe)"
		}
		if _, err := fmt.Fprintf(a.Out, "  %-28s %-12s %s%s\n", h.Target, strings.Join(h.Roles, ","), units, mark); err != nil {
			return err
		}
	}
	if len(hs.With("app")) == 0 {
		a.Warn("no host has role app — deploy/restart have nowhere to go")
	}
	if !hs.Has(hs.Primary) {
		a.Warn("APP=%s (the probed host) is not listed in %s", hs.Primary, hs.File)
	}
	return nil
}
