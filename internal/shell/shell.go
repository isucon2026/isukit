// Package shell runs the commands that still live in bash.
//
// The embedded kit (isukit, lib/, remote/) is unpacked once per content hash
// into the user cache dir and run with bash from there, so the bash entry
// point finds lib/ and remote/ next to itself exactly as in a git checkout.
package shell

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"

	"github.com/isucon2026/isukit"
)

// Dir returns the directory holding the unpacked kit, unpacking it if needed.
func Dir() (string, error) {
	sum, err := digest(isukit.Kit)
	if err != nil {
		return "", err
	}
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	dir := filepath.Join(base, "isukit", sum[:16])
	if _, err := os.Stat(filepath.Join(dir, ".complete")); err == nil {
		return dir, nil
	}
	// unpack into a temp dir and rename, so a concurrent or interrupted run
	// never sees half a kit
	tmp, err := os.MkdirTemp(filepath.Dir(dir), ".unpack-")
	if err != nil {
		if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
			return "", err
		}
		if tmp, err = os.MkdirTemp(filepath.Dir(dir), ".unpack-"); err != nil {
			return "", err
		}
	}
	if err := unpack(isukit.Kit, tmp); err != nil {
		os.RemoveAll(tmp)
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, ".complete"), nil, 0o644); err != nil {
		os.RemoveAll(tmp)
		return "", err
	}
	if err := os.Rename(tmp, dir); err != nil {
		os.RemoveAll(tmp)
		if _, statErr := os.Stat(filepath.Join(dir, ".complete")); statErr == nil {
			return dir, nil // another run won the race
		}
		return "", err
	}
	return dir, nil
}

// Run executes `bash <kit>/isukit args...` with the caller's stdio, env and
// working directory, and returns bash's exit code.
func Run(args []string) (int, error) {
	dir, err := Dir()
	if err != nil {
		return 1, fmt.Errorf("unpacking the kit: %w", err)
	}
	cmd := exec.Command("bash", append([]string{filepath.Join(dir, "isukit")}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err = cmd.Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode(), nil
	}
	if err != nil {
		return 1, err
	}
	return 0, nil
}

func unpack(src fs.FS, dst string) error {
	return fs.WalkDir(src, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(dst, filepath.FromSlash(p))
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		in, err := src.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, in); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	})
}

func digest(src fs.FS) (string, error) {
	var paths []string
	if err := fs.WalkDir(src, ".", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			paths = append(paths, p)
		}
		return err
	}); err != nil {
		return "", err
	}
	sort.Strings(paths)
	h := sha256.New()
	for _, p := range paths {
		b, err := fs.ReadFile(src, p)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(h, "%s\x00%d\x00", p, len(b))
		h.Write(b)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
