package cli

import (
	"fmt"
	"regexp"
	"runtime/debug"

	"github.com/spf13/cobra"

	"github.com/isucon2026/isukit"
)

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "the kit version and the module version / commit this binary was built from",
		Args:  cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			_, err := fmt.Fprintf(c.OutOrStdout(), "isukit %s (%s)\n", kitVersion(), buildVersion())
			return err
		},
	}
}

// kitVersion is KIT_VERSION from the embedded bash entry point.
func kitVersion() string {
	b, err := isukit.Kit.ReadFile("isukit")
	if err != nil {
		return "?"
	}
	if m := regexp.MustCompile(`(?m)^KIT_VERSION=(\S+)`).FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return "?"
}

// buildVersion is what `go install ...@<tag>` recorded: the module version,
// else the commit (and whether the tree was dirty) for a local build.
func buildVersion() string {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown build"
	}
	if v := bi.Main.Version; v != "" && v != "(devel)" {
		return v
	}
	rev, dirty := "", ""
	for _, s := range bi.Settings {
		switch s.Key {
		case "vcs.revision":
			rev = s.Value
		case "vcs.modified":
			if s.Value == "true" {
				dirty = "-dirty"
			}
		}
	}
	if len(rev) > 7 {
		rev = rev[:7]
	}
	if rev == "" {
		return "devel"
	}
	return "devel " + rev + dirty
}
