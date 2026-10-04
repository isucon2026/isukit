#!/usr/bin/env bash
# isukit installer.
#   curl -fsSL https://raw.githubusercontent.com/isucon2026/isukit/main/install.sh | bash
# Args after the script (via `bash -s --`) are forwarded to the freshly
# installed isukit, so this also works as a one-shot:
#   curl -fsSL .../install.sh | bash -s -- go <repo-url> ubuntu@1.2.3.4 -i ~/.ssh/key.pem
# Contest day: install the frozen tag, not whatever main is that morning:
#   curl -fsSL .../install.sh | ISUKIT_REF=v1.0.0 bash
set -euo pipefail

REPO_URL="https://github.com/isucon2026/isukit"
SRC="${ISUKIT_HOME:-$HOME/.isukit-src}"
REF="${ISUKIT_REF:-}"   # a tag / branch / commit to pin to; empty = follow main

say()  { printf '\033[36m:: %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[33m~~ %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"

if [ -d "$SRC/.git" ]; then
  CURRENT_ORIGIN="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
  if [ "$CURRENT_ORIGIN" != "$REPO_URL" ]; then
    say "repointing origin: $CURRENT_ORIGIN -> $REPO_URL"
    git -C "$SRC" remote set-url origin "$REPO_URL"
  fi
  say "updating $SRC"
  git -C "$SRC" fetch -q --tags origin
  if [ -n "$REF" ]; then
    git -C "$SRC" checkout -q "$REF" || die "no such ref: $REF"
  else
    # a previous pinned install leaves a detached HEAD: go back to main first
    git -C "$SRC" checkout -q main && git -C "$SRC" pull -q --ff-only
  fi
else
  say "cloning $REPO_URL to $SRC"
  git clone -q "$REPO_URL" "$SRC"
  [ -z "$REF" ] || git -C "$SRC" checkout -q "$REF" || die "no such ref: $REF"
fi
[ -z "$REF" ] || say "pinned to $REF ($(git -C "$SRC" rev-parse --short HEAD))"

pick_bin_dir() {
  if [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    if [ -w "$HOME/.local/bin" ]; then printf '%s\n' "$HOME/.local/bin"; return; fi
  fi
  if [ -w /usr/local/bin ] 2>/dev/null; then printf '%s\n' /usr/local/bin; return; fi
  if [ -t 0 ] && command -v sudo >/dev/null 2>&1; then printf '%s\n' /usr/local/bin__sudo; return; fi
  mkdir -p "$HOME/.local/bin"
  printf '%s\n' "$HOME/.local/bin"
}

BIN_DIR=$(pick_bin_dir)
NEED_SUDO=0
if [ "$BIN_DIR" = "/usr/local/bin__sudo" ]; then
  BIN_DIR=/usr/local/bin
  NEED_SUDO=1
fi

LINK="$BIN_DIR/isukit"
if [ "$NEED_SUDO" = 1 ]; then
  sudo ln -sf "$SRC/isukit" "$LINK"
else
  mkdir -p "$BIN_DIR"
  ln -sf "$SRC/isukit" "$LINK"
fi
say "linked $LINK -> $SRC/isukit"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on PATH — add:"; printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" >&2 ;;
esac

VERSION=$(grep -m1 '^KIT_VERSION=' "$SRC/isukit" | cut -d= -f2)
say "installed: $LINK (KIT_VERSION=$VERSION)"

# Install Claude skill if present
SKILL_SRC="$SRC/skills/isucon"
if [ -d "$SKILL_SRC" ]; then
  mkdir -p "$HOME/.claude/skills"

  SKILL_LINK="$HOME/.claude/skills/isucon"
  SKILL_SRC_ABS="$(cd "$SKILL_SRC" && pwd)"

  if [ -L "$SKILL_LINK" ]; then
    CURRENT_TARGET="$(readlink "$SKILL_LINK")"
    if [ "$CURRENT_TARGET" = "$SKILL_SRC_ABS" ]; then
      say "Claude skill already installed: /isucon"
    else
      warn "Claude skill symlink points to a different location:"
      printf '  current:  %s\n' "$CURRENT_TARGET" >&2
      printf '  expected: %s\n' "$SKILL_SRC_ABS" >&2
      warn "resolve manually, then re-run this installer"
    fi
  elif [ -e "$SKILL_LINK" ]; then
    warn "Claude skill path exists but is not a symlink: $SKILL_LINK"
    warn "resolve manually, then re-run this installer"
  else
    if ln -s "$SKILL_SRC_ABS" "$SKILL_LINK"; then
      say "installed Claude skill: /isucon"
    else
      warn "failed to create Claude skill symlink — proceeding without it"
    fi
  fi
fi

if [ "$#" -gt 0 ]; then
  exec "$LINK" "$@"
fi
