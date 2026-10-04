// Command isukit is the ISUCON bootstrap + measurement loop.
package main

import (
	"os"

	"github.com/isucon2026/isukit/internal/cli"
)

func main() {
	os.Exit(cli.Execute(os.Args[1:]))
}
