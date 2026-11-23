#!/usr/bin/env bash
# Run a command from an Ansible task and show its output live.
#
# Ansible captures a task's output and prints it only when the task ends.
# This writes the output straight to the controlling terminal instead, so
# long steps (image builds, minikube start, installs, rollouts) stream like
# they would in a shell. The command's exit code is preserved.
#
# Usage:
#   live-run.sh [--log FILE] [--label TEXT] -- COMMAND [ARGS...]
#
#   --log FILE    also write the full output to FILE
#   --label TEXT  heading printed above the output
#
# Without a terminal (CI, background runs) or with LIVE_OUTPUT=0, the output
# goes to stdout for Ansible to capture; with --log it goes to FILE and only
# the last 50 lines are printed.

set -uo pipefail

log=""
label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) log="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "usage: $(basename "$0") [--log FILE] [--label TEXT] -- COMMAND [ARGS...]" >&2
  exit 2
fi

# Ansible runs tasks in processes detached from the terminal, so /dev/tty is
# not available there. Find the terminal of the nearest ancestor that has one
# (ansible-playbook itself). PR_TESTER_TTY overrides the lookup.
find_tty() {
  if [[ -n "${PR_TESTER_TTY:-}" ]] && { : > "$PR_TESTER_TTY"; } 2>/dev/null; then
    echo "$PR_TESTER_TTY"; return 0
  fi
  if { : > /dev/tty; } 2>/dev/null; then
    echo /dev/tty; return 0
  fi
  local pid=$$ ppid t i
  for (( i = 0; i < 20; i++ )); do
    read -r ppid t < <(ps -o ppid= -o tty= -p "$pid" 2>/dev/null) || return 1
    if [[ -n "$t" && "$t" != "?" && "$t" != "??" ]]; then
      [[ "$t" == /dev/* ]] || t="/dev/$t"
      if { : > "$t"; } 2>/dev/null; then echo "$t"; return 0; fi
    fi
    [[ -z "$ppid" || "$ppid" -le 1 ]] && return 1
    pid=$ppid
  done
  return 1
}

live=0
term=""
if [[ "${LIVE_OUTPUT:-1}" != "0" ]] && term=$(find_tty); then
  live=1
fi

# Indent every line under the Ansible task header; flush per line.
indent() { awk -v p="${LIVE_PREFIX-    │ }" '{ print p $0; fflush() }'; }

if (( live )); then
  {
    printf '\n'
    [[ -n "$label" ]] && printf '  ▶ %s\n' "$label"
    printf '    $ %s\n' "$*"
    [[ -n "$log" ]] && printf '    (log: %s)\n' "$log"
  } > "$term"
  # Keep a copy even without --log, so a failure can be reported to Ansible.
  capture="${log:-$(mktemp)}"
  "$@" 2>&1 | tee "$capture" | indent > "$term"
  rc=${PIPESTATUS[0]}
  if (( rc == 0 )); then
    printf '  ✔ done\n\n' > "$term"
  else
    printf '  ✘ exit code %d\n\n' "$rc" > "$term"
    # The live output went to the terminal; give Ansible the tail too, so the
    # task's failure report (stdout) shows the error instead of nothing.
    echo "--- last 40 lines (full output above${log:+, log: $log}) ---"
    tail -n 40 "$capture"
  fi
  [[ -z "$log" ]] && rm -f "$capture"
else
  if [[ -n "$log" ]]; then
    "$@" > "$log" 2>&1
    rc=$?
    tail -n 50 "$log"
  else
    "$@" 2>&1
    rc=$?
  fi
fi

exit "$rc"