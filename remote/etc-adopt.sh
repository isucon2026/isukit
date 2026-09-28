#!/bin/bash
# Runs ON THE APP HOST, sent by `isukit etc adopt` over `ssh host bash -s`.
#
# Moves the real nginx / mysql / app-unit config files into <REPO>/etc/<same
# path minus /etc/> and leaves a symlink in /etc pointing at each, so the repo is
# the only copy and every tuning change is a git diff. Each adopted file keeps
# its pre-link original next to it as <path>.orig. After linking, each tier is
# checked (nginx -t + reload, daemon-reload, mysql restart + SELECT 1) and a tier
# that fails is rolled back on its own.
#
# Inputs (isukit prepends them as VAR=value lines):
#   REPO       server dir whose etc/ receives the files (required)
#   APP_UNIT   the app's systemd unit, adopted too if it lives in /etc/systemd/system
#   TARGETS    space-separated /etc paths to adopt; empty = discover
#   ETC_ROOT   default /etc (tests point it at a throwaway tree)
#   SUDO       default "sudo -n" (tests set it empty)

set -u
: "${REPO:?REPO is required}"
SUDO="${SUDO-sudo -n}"
E=$(cd "${ETC_ROOT:-/etc}" && pwd -P)
DEST="$REPO/etc"
RC=0
[ -d "$REPO" ] || { echo "etc: repo dir $REPO does not exist on this host" >&2; exit 1; }
OWNER=$(stat -c %U "$REPO" 2>/dev/null || stat -f %Su "$REPO" 2>/dev/null || echo root)
JOURNAL=$(mktemp); LIST=$(mktemp)
trap 'rm -f "$JOURNAL" "$LIST"' EXIT

resolve_link() { # one hop, made absolute: sites-enabled/x -> /etc/nginx/sites-available/x
  local t
  t=$(readlink "$1")
  case "$t" in /*) ;; *) t="$(dirname "$1")/$t" ;; esac
  printf "%s/%s\n" "$(cd "$(dirname "$t")" 2>/dev/null && pwd -P || dirname "$t")" "$(basename "$t")"
}

discover() {
  local f t
  if [ -e "$E/nginx/nginx.conf" ] || [ -L "$E/nginx/nginx.conf" ]; then
    echo "$E/nginx/nginx.conf"
    for f in "$E"/nginx/sites-enabled/* "$E"/nginx/conf.d/*.conf; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      case "$f" in */00-isukit.conf) continue ;; esac
      if [ -L "$f" ]; then
        t=$(resolve_link "$f")
        case "$t" in "$E"/*) echo "$t"; continue ;; esac
      fi
      echo "$f"
    done
  fi
  # every .cnf that configures the server itself; client-only files and the
  # distro alternatives symlink (/etc/mysql/my.cnf) are left alone.
  if [ -d "$E/mysql" ]; then
    find "$E/mysql" \( -type f -o -type l \) -name "*.cnf" 2>/dev/null | sort | while read -r f; do
      if [ -L "$f" ]; then
        case "$(readlink "$f")" in "$DEST"/*) echo "$f" ;; esac
        continue
      fi
      grep -qE "^\[(mysqld|server|mariadb)\]" "$f" && echo "$f"
    done
  fi
  if [ -n "${APP_UNIT:-}" ]; then
    f="$E/systemd/system/$APP_UNIT"
    if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; fi
  fi
  return 0
}

adopt_one() {
  local f="$1" rel dst g mode
  case "$f" in "$E"/*) ;; *) echo "skip:    $f is not under $E"; return 0 ;; esac
  rel="${f#"$E"/}"; dst="$DEST/$rel"
  case "$rel" in nginx/*) g=nginx ;; mysql/*) g=mysql ;; systemd/*) g=systemd ;; *) g=other ;; esac
  if [ -L "$f" ]; then
    if [ "$(readlink "$f")" = "$dst" ]; then
      echo "ok:      $f -> $dst"
    else
      echo "skip:    $f is already a symlink (-> $(readlink "$f")), not touching it"
    fi
    return 0
  fi
  if [ ! -e "$f" ]; then
    # fresh instance: the file only exists in the repo. link it into place.
    [ -f "$dst" ] || { echo "skip:    $f not found (and not in the repo)"; return 0; }
    $SUDO mkdir -p "$(dirname "$f")" && $SUDO ln -s "$dst" "$f" || { echo "FAILED:  could not link $f" >&2; RC=1; return 0; }
    echo "linked:  $f -> $dst (new — absent from $E)"
    echo "$g new $f" >> "$JOURNAL"
    return 0
  fi
  [ -f "$f" ] || { echo "skip:    $f is not a regular file"; return 0; }
  $SUDO mkdir -p "$(dirname "$dst")" || { echo "FAILED:  mkdir $(dirname "$dst")" >&2; RC=1; return 0; }
  [ -e "$f.orig" ] || $SUDO cp -p "$f" "$f.orig" || { echo "FAILED:  could not back up $f" >&2; RC=1; return 0; }
  if [ -e "$dst" ]; then
    # the repo already has it (re-creating a box from the repo): the repo wins.
    if cmp -s "$f" "$dst"; then
      echo "linked:  $f -> $dst (repo copy identical)"
    else
      echo "linked:  $f -> $dst (REPO COPY WINS — the $E version differed, kept as $f.orig)"
    fi
    $SUDO rm -f "$f"; mode=existing
  else
    $SUDO mv "$f" "$dst" || { echo "FAILED:  could not move $f into the repo" >&2; RC=1; return 0; }
    echo "linked:  $f -> $dst (moved into repo)"
    mode=moved
  fi
  $SUDO ln -s "$dst" "$f"
  echo "$g $mode $f" >> "$JOURNAL"
}

has() { grep -q "^$1 " "$JOURNAL"; }
rollback() { # rollback <group> -- put every link made in that group back the way it was
  local g m f
  while read -r g m f; do
    [ "$g" = "$1" ] || continue
    $SUDO rm -f "$f"
    case "$m" in
      moved)    $SUDO mv "$DEST/${f#"$E"/}" "$f" ;;
      existing) $SUDO cp -p "$f.orig" "$f" ;;
    esac
    echo "rolled back: $f"
  done < "$JOURNAL"
}

if [ -n "${TARGETS:-}" ]; then
  for t in $TARGETS; do printf "%s\n" "$t"; done > "$LIST"
else
  discover | sort -u > "$LIST"
fi
while read -r f; do adopt_one "$f"; done < "$LIST"

# verify each tier actually starts from the linked files; undo that tier if not.
if has nginx; then
  if $SUDO nginx -t >/dev/null 2>&1 && $SUDO systemctl reload nginx; then
    echo "nginx: config OK through the links, reloaded"
  else
    echo "nginx: FAILED with the linked config — rolling back nginx" >&2
    $SUDO nginx -t 2>&1 | tail -5 >&2
    rollback nginx
    $SUDO systemctl reload nginx 2>/dev/null || true
    RC=1
  fi
fi
if has systemd; then
  $SUDO systemctl daemon-reload && echo "systemd: daemon-reload (unit files now read through the links)"
fi
if has mysql; then
  # Ubuntu confines mysqld with AppArmor, which only lets it read /etc/mysql/**.
  # Without this, mysqld cannot follow the link into /home and fails to start.
  for p in usr.sbin.mysqld usr.sbin.mariadbd; do
    prof="$E/apparmor.d/$p"
    [ -f "$prof" ] || continue
    loc="$E/apparmor.d/local/$p"
    if ! grep -qF "$DEST/mysql/** r," "$loc" 2>/dev/null; then
      $SUDO mkdir -p "$E/apparmor.d/local"
      printf "  %s/mysql/ r,\n  %s/mysql/** r,\n" "$DEST" "$DEST" | $SUDO tee -a "$loc" >/dev/null
      echo "apparmor: $loc now allows $DEST/mysql/**"
    fi
    if command -v apparmor_parser >/dev/null 2>&1; then
      $SUDO apparmor_parser -r "$prof" && echo "apparmor: reloaded $p"
    fi
    # a record only (apparmor itself must keep reading it from /etc)
    $SUDO mkdir -p "$DEST/apparmor.d/local" && $SUDO cp "$loc" "$DEST/apparmor.d/local/$p"
  done
  DBU=""
  for s in mysql mariadb; do systemctl is-active --quiet "$s" 2>/dev/null && DBU="$s" && break; done
  if [ -n "$DBU" ]; then
    if $SUDO systemctl restart "$DBU" && $SUDO mysql -e "SELECT 1" >/dev/null 2>&1; then
      echo "mysql: restarted $DBU, it reads its config through the links"
    else
      echo "mysql: FAILED to come back with the linked config — rolling back mysql" >&2
      rollback mysql
      $SUDO systemctl restart "$DBU" || true
      RC=1
    fi
  else
    echo "mysql: no active mysql/mariadb unit — linked, but not restarted or verified"
  fi
fi
$SUDO chown -R "$OWNER" "$DEST" 2>/dev/null || true
exit $RC
