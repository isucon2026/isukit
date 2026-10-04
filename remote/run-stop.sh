#!/bin/bash
# Runs ON EVERY HOST, sent by `isukit bench` over `ssh host bash -s`.
#
# Closes the measurement window run-start.sh opened: stops the samplers and
# prints a two-line summary of the run for this host —
#   cpu    avg 94%  max 100%  iowait 1%  steal 0%  (user+sys over all 2 cores, 61 samples)
#   procs  isuride 142%  nginx 31%  mysqld 5%  (avg; 100% = one core)
# which is what says which host (and which process on it) was the bottleneck.
# Prints nothing if no window was open.

set -u
D=/tmp/isukit-run
[ -f "$D/pids" ] || exit 0
# shellcheck disable=SC2046  # one pid per word
kill $(cat "$D/pids") 2>/dev/null || true
rm -f "$D/pids"
sleep 0.2

if [ -s "$D/vmstat.log" ]; then
  awk -v ncpu="$(cat "$D/ncpu" 2>/dev/null || echo 1)" '
    # the header names the columns; they moved between procps versions (gu, st)
    / us / && / sy / { for (i = 1; i <= NF; i++) col[$i] = i; next }
    $1 ~ /^[0-9]+$/ && ("us" in col) {
      if (!skipped) { skipped = 1; next }   # first row = averages since boot
      c = $col["us"] + $col["sy"]
      n++; sum += c; if (c > max) max = c
      wa += ("wa" in col) ? $col["wa"] : 0
      st += ("st" in col) ? $col["st"] : 0
    }
    END {
      if (n == 0) { print "cpu    (no samples — the run was shorter than 2s?)"; exit }
      printf "cpu    avg %d%%  max %d%%  iowait %d%%  steal %d%%  (user+sys over all %d cores, %d samples)\n",
        sum / n + 0.5, max, wa / n + 0.5, st / n + 0.5, ncpu, n
    }' "$D/vmstat.log"
fi

if [ -s "$D/pidstat.log" ]; then
  awk '
    # "# Time UID PID %usr %system %guest %wait %CPU CPU Command": the leading
    # "#" is its own field, so data column k is header column k+1.
    /^#/ { for (i = 2; i <= NF; i++) { if ($i == "%CPU") cpu = i - 1; if ($i == "Command") cmd = i - 1 }; next }
    NF == 0 || !cpu || !cmd { next }
    {
      t[$1] = 1
      name = $cmd; for (i = cmd + 1; i <= NF; i++) name = name " " $i
      sub(/^\|__/, "", name)
      load[name] += $cpu
    }
    END {
      samples = 0; for (x in t) samples++
      if (samples == 0) exit
      out = "procs"
      for (k = 0; k < 5; k++) {
        best = ""; bv = -1
        for (p in load) if (load[p] > bv) { bv = load[p]; best = p }
        if (best == "" || bv / samples < 1) break
        out = out sprintf("  %s %d%%", best, bv / samples + 0.5)
        delete load[best]
      }
      print out "  (avg; 100% = one core)"
    }' "$D/pidstat.log"
fi
