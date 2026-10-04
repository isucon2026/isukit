// Package config reads isukit's state files: .isukit/config (written by hand
// and by isukit) and the probe manifests (written by `printf %q`). Both are
// shell assignments the bash side `source`s, so this reads the same subset of
// shell syntax: KEY=word per line, a word being any mix of bare text with
// backslash escapes, '...', "..." and $'...', ending at unquoted whitespace
// (anything after it is a comment or ignored).
package config

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// Values maps each assigned name to its value; a later assignment wins.
type Values map[string]string

// Get returns the value of key, or "" when it is unset.
func (v Values) Get(key string) string { return v[key] }

// ReadFile parses a shell-assignment file. A missing file is an error.
func ReadFile(path string) (Values, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return Parse(f)
}

// Parse reads KEY=word lines; blank lines, comments and anything that is not
// an assignment are skipped, as `source` would treat them as no-ops for us.
func Parse(r io.Reader) (Values, error) {
	vals := Values{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	n := 0
	for sc.Scan() {
		n++
		line := strings.TrimLeft(sc.Text(), " \t")
		if line == "" || line[0] == '#' {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 || !isName(line[:eq]) {
			continue
		}
		val, err := word(line[eq+1:])
		if err != nil {
			return nil, fmt.Errorf("line %d: %s: %w", n, line[:eq], err)
		}
		vals[line[:eq]] = val
	}
	return vals, sc.Err()
}

func isName(s string) bool {
	for i, c := range s {
		if !(c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return s != ""
}

// word decodes one shell word from the start of s.
func word(s string) (string, error) {
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t':
			return b.String(), nil
		case c == '\\':
			if i+1 < len(s) {
				b.WriteByte(s[i+1])
			}
			i += 2
		case c == '\'':
			j := strings.IndexByte(s[i+1:], '\'')
			if j < 0 {
				return "", fmt.Errorf("unterminated '")
			}
			b.WriteString(s[i+1 : i+1+j])
			i += j + 2
		case c == '"':
			i++
			for ; i < len(s) && s[i] != '"'; i++ {
				if s[i] == '\\' && i+1 < len(s) && strings.IndexByte("\"\\$`", s[i+1]) >= 0 {
					i++
				}
				b.WriteByte(s[i])
			}
			if i >= len(s) {
				return "", fmt.Errorf(`unterminated "`)
			}
			i++
		case c == '$' && i+1 < len(s) && s[i+1] == '\'':
			out, used, err := ansiC(s[i+2:])
			if err != nil {
				return "", err
			}
			b.WriteString(out)
			i += 2 + used
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String(), nil
}

// ansiC decodes the body of $'...' up to and including its closing quote.
func ansiC(s string) (string, int, error) {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\'' {
			return b.String(), i + 1, nil
		}
		if c != '\\' || i+1 >= len(s) {
			b.WriteByte(c)
			continue
		}
		i++
		switch e := s[i]; e {
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		case 'a':
			b.WriteByte('\a')
		case 'b':
			b.WriteByte('\b')
		case 'e', 'E':
			b.WriteByte(0x1b)
		case 'x':
			j := i + 1
			for j < len(s) && j < i+3 && strings.IndexByte("0123456789abcdefABCDEF", s[j]) >= 0 {
				j++
			}
			v, err := strconv.ParseUint(s[i+1:j], 16, 8)
			if err != nil {
				return "", 0, fmt.Errorf("bad \\x escape")
			}
			b.WriteByte(byte(v))
			i = j - 1
		default:
			if e >= '0' && e <= '7' {
				j := i
				for j < len(s) && j < i+3 && s[j] >= '0' && s[j] <= '7' {
					j++
				}
				v, _ := strconv.ParseUint(s[i:j], 8, 8)
				b.WriteByte(byte(v))
				i = j - 1
			} else {
				b.WriteByte(e) // \\ \' \" and anything else: the character itself
			}
		}
	}
	return "", 0, fmt.Errorf("unterminated $'")
}
