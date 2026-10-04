# shellcheck shell=bash
# isukit lib/go.sh — `isukit go`: argument parsing and the one-shot sequence.
# Sourced by ../isukit; not meant to run on its own.

dump_argv() { # dump_argv -- print full_argv (set by cmd_go), one element per line
  local n=0 a
  printf 'received %d argument(s):\n' "${#full_argv[@]}"
  for a in "${full_argv[@]}"; do
    n=$((n+1))
    printf "  [%d] '%s'\n" "$n" "$a"
  done
}

die_unplaced() { # die_unplaced <bad-arg> -- self-diagnosing die: full argv dump via the die helper
  local msg
  msg="isukit go: could not place argument: '$1'
  $(dump_argv)"
  die "$msg"
}

cmd_go() {
  local -a full_argv=(go "$@")
  # --new <owner/name>: no team repo yet — build it from the server (see repo_new_*)
  local new_slug=""
  if [ "${1:-}" = "--new" ]; then
    new_slug="${2:-}"
    case "$new_slug" in */*) ;; *) die "usage: isukit go --new <owner/repo> <app-ssh-target> ... — e.g. --new myteam/isucon2026" ;; esac
    shift 2
    set -- "--new:$new_slug" "$@"
  fi
  local url="${1:-}" apph="${2:-}"
  [ -n "$url" ] && [ -n "$apph" ] || die "usage: isukit go <repo-url | --new owner/repo> <app-ssh-target> [bench-ssh-target] [-i keyfile] [-p port] [--ssh-opts 'raw'] [--invite user,user] [--debug-args]"
  shift 2 || true

  local a
  for a in "$@"; do
    if [ "$a" = "--debug-args" ]; then
      say "isukit go: argv dump (--debug-args — no action taken)"
      dump_argv >&2
      exit 0
    fi
  done

  local benchh="" keyfile="" port="" raw_opts="" invite=""
  while [ "$#" -gt 0 ]; do
    is_blank "$1" && { shift; continue; }
    case "$1" in
      -i=*)             keyfile="${1#-i=}"; shift ;;
      -i?*)             keyfile="${1#-i}"; shift ;;
      -i)
        [ "$#" -ge 2 ] || die "-i needs a keyfile argument"
        keyfile="$2"; shift 2 ;;
      --identity=*)     keyfile="${1#--identity=}"; shift ;;
      --identity)
        [ "$#" -ge 2 ] || die "--identity needs a keyfile argument"
        keyfile="$2"; shift 2 ;;
      --key=*)          keyfile="${1#--key=}"; shift ;;
      --key)
        [ "$#" -ge 2 ] || die "--key needs a keyfile argument"
        keyfile="$2"; shift 2 ;;
      --port=*)         port="${1#--port=}"; shift ;;
      --port)
        [ "$#" -ge 2 ] || die "--port needs a port argument"
        port="$2"; shift 2 ;;
      -p)
        [ "$#" -ge 2 ] || die "-p needs a port argument"
        port="$2"; shift 2 ;;
      --invite=*)       invite="${1#--invite=}"; shift ;;
      --invite)
        [ "$#" -ge 2 ] || die "--invite needs a comma-separated list of GitHub users"
        invite="$2"; shift 2 ;;
      --ssh-opts=*)     raw_opts="${1#--ssh-opts=}"; shift ;;
      --ssh-opts)
        [ "$#" -ge 2 ] || die "--ssh-opts needs an argument"
        raw_opts="$2"; shift 2 ;;
      --debug-args)
        shift ;;
      -*)
        die_unplaced "$1" ;;
      *)
        if [ -n "$benchh" ] && [ -z "$keyfile" ] && looks_like_keyfile "$1"; then
          warn "'$1' looks like an identity file given without -i — using it as the keyfile"
          keyfile="$1"
        elif [ -n "$benchh" ]; then
          die_unplaced "$1"
        else
          benchh="$1"
        fi
        shift ;;
    esac
  done
  if [ -n "$keyfile" ]; then
    keyfile=$(expand_tilde "$keyfile")
  fi

  if [ -n "$new_slug" ]; then
    repo_new_prepare "$new_slug"
  else
    [ -z "$invite" ] || warn "--invite only applies with --new (the repo already exists) — ignored"
    cmd_init "$url"
  fi
  cmd_host app "$apph"
  cmd_host bench "${benchh:-$apph}"

  if [ -n "$keyfile" ] || [ -n "$port" ]; then
    local abskey=""
    if [ -n "$keyfile" ]; then
      abskey=$(abspath "$keyfile")
      check_keyfile "$abskey"
    fi
    {
      go_ssh_host_block isukit-app "$apph" "$abskey" "$port"
      printf '\n'
      go_ssh_host_block isukit-bench "${benchh:-$apph}" "$abskey" "$port"
      # every other contest host (isukit host add / host role <ip>) gets the
      # same key, user and port — ssh -F reads nothing else.
      printf '\n'
      local cuser=""
      [ "${apph#*@}" != "$apph" ] && cuser="${apph%%@*}"
      go_ssh_catchall_block "$cuser" "$abskey" "$port"
    } > "$STATE/ssh_config"
    chmod 600 "$STATE/ssh_config" 2>/dev/null || true
    local ssh_opts_line="-F $STATE/ssh_config"
    [ -n "$raw_opts" ] && ssh_opts_line="$ssh_opts_line $raw_opts"
    cmd_host app "isukit-app" "$ssh_opts_line"
    cmd_host bench "isukit-bench" "$ssh_opts_line"
    say "ssh config written to $STATE/ssh_config (aliases isukit-app / isukit-bench)"
  elif [ -n "$raw_opts" ]; then
    cmd_host app "$apph" "$raw_opts"
    cmd_host bench "${benchh:-$apph}" "$raw_opts"
  fi

  cmd_probe
  # before setup / logs on: the config baseline must be the server as handed out
  [ -n "$new_slug" ] && repo_new_baseline "$new_slug" "$invite"
  cmd_setup
  cmd_logs on

  local final_bench_cmd final_bench_mode
  final_bench_cmd=$(. "$CONF" 2>/dev/null; printf '%s' "${BENCH_CMD:-}")
  final_bench_mode=$(. "$CONF" 2>/dev/null; printf '%s' "${BENCH_MODE:-auto}")
  if [ "$final_bench_mode" = "manual" ]; then
    say "ready. BENCH_MODE = manual — start a run in the contest portal, then record it:"
    say "    isukit bench --score <N> \"baseline\""
  elif [ -n "$final_bench_cmd" ]; then
    say "ready. BENCH_CMD = $final_bench_cmd"
    say "next: isukit bench baseline"
  else
    warn "ready, but BENCH_CMD is empty and BENCH_MODE is auto — pick one:"
    warn "    isukit benchcmd '<command>'   (a benchmarker you can run yourself)"
    warn "    isukit benchmode manual       (the portal runs it; you type the score)"
  fi
}
