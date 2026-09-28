#!/usr/bin/env bash
# isukit user-data — EC2 first-boot payload, runs as root while humans are still
# reading the manual. Install-only: never reconfigures the app, never restarts
# the app unit, never touches nginx logging / mysql slow log / envcheck — those
# are 'isukit logs on' territory, gated behind the operator's own call, because
# logging left on during a scoring run costs score and fills the disk.
#
# No 'set -e': a failed apt-get must not abort the remaining installs.
set -u

log_file=/var/log/isukit-userdata.log
marker_file=/var/log/isukit-userdata.done

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$log_file"; }

installed=""
step() { # step <label> <cmd...> -- never aborts the script; records pass/fail
  local label="$1"; shift
  if "$@" >>"$log_file" 2>&1; then
    log "OK: $label"
    installed="$installed $label"
  else
    log "FAIL: $label (continuing)"
  fi
}

log "isukit user-data start"

step apt-update apt-get update -y
step percona-toolkit apt-get install -y percona-toolkit
step sysstat apt-get install -y sysstat
step git apt-get install -y git
step jq apt-get install -y jq
step unzip apt-get install -y unzip
step curl apt-get install -y curl
step tree apt-get install -y tree

install_alp() { # latest github release tarball for this host's arch; no apt package exists
  local arch url tmp
  case "$(uname -m)" in
    x86_64)          arch=amd64 ;;
    aarch64|arm64)   arch=arm64 ;;
    *) log "alp: unsupported arch $(uname -m)"; return 1 ;;
  esac
  url=$(curl -fsSL --max-time 10 https://api.github.com/repos/tkuchiki/alp/releases/latest \
    | grep -o "\"browser_download_url\": *\"[^\"]*linux_${arch}\.tar\.gz\"" \
    | head -1 | cut -d'"' -f4)
  [ -n "$url" ] || return 1
  tmp=$(mktemp -d) || return 1
  curl -fsSL --max-time 20 "$url" -o "$tmp/alp.tar.gz" && tar -xzf "$tmp/alp.tar.gz" -C "$tmp" \
    && install -m 755 "$tmp/alp" /usr/local/bin/alp
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}
step alp install_alp

if id isucon >/dev/null 2>&1; then
  step isucon-isukit-dir bash -c 'mkdir -p /home/isucon/.isukit && chown isucon:isucon /home/isucon/.isukit'
fi

printf '%s\n' "$installed" | tr ' ' '\n' | sed '/^$/d' > "$marker_file"
log "isukit user-data done: ${installed# }"
