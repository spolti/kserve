#!/usr/bin/env bash
# Wait for an InferenceService or LLMInferenceService to become Ready and show
# what is happening while it does:
#   - Ready condition and the reasons of conditions that are not True
#   - pod phase and every container's state (init containers included)
#   - new events for the workload and its pods
#   - live logs of every container as soon as it starts, re-followed after
#     restarts (storage-initializer, kserve-container, agent, ...)
# On timeout it prints a short diagnosis and exits 1.
#
# Usage:
#   watch-workload.sh --kind inferenceservice|llminferenceservice --name NAME
#                     --namespace NS [--selector LABELS] [--timeout SECONDS]
#
# Output goes to the terminal when there is one (so it shows live under the
# Ansible task), otherwise to stdout. LIVE_OUTPUT=0 forces stdout.

set -uo pipefail

kind=""; name=""; ns=""; selector=""; timeout=300; interval=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --namespace) ns="$2"; shift 2 ;;
    --selector) selector="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$kind" || -z "$name" || -z "$ns" ]]; then
  echo "usage: $(basename "$0") --kind KIND --name NAME --namespace NS [--selector LABELS] [--timeout S]" >&2
  exit 2
fi
if [[ -z "$selector" ]]; then
  case "$kind" in
    inferenceservice|isvc) selector="serving.kserve.io/inferenceservice=${name}" ;;
    llminferenceservice|llmisvc) selector="app.kubernetes.io/name=${name},app.kubernetes.io/part-of=llminferenceservice" ;;
    *) echo "--selector is required for kind ${kind}" >&2; exit 2 ;;
  esac
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

out=/dev/stdout
if [[ "${LIVE_OUTPUT:-1}" != "0" ]] && term=$(find_tty); then
  out=$term
fi

state=$(mktemp -d)
followers=()
# followers holds the kubectl PIDs; their awk formatters exit on EOF.
cleanup() {
  local pid
  for pid in "${followers[@]}"; do kill "$pid" 2>/dev/null; done
  for pid in "${followers[@]}"; do wait "$pid" 2>/dev/null; done
  rm -rf "$state"
}
trap cleanup EXIT INT TERM

say() { printf '%s\n' "$*" > "$out"; }
ts() { date '+%H:%M:%S'; }

# Print a line only when it differs from the last time it was printed.
# Compared without the timestamp, which is added on output.
print_if_changed() {
  local key="$1" content="$2"
  if [[ "$content" != "$(cat "$state/$key" 2>/dev/null)" ]]; then
    printf '%s' "$content" > "$state/$key"
    [[ -n "$content" ]] && say "  [$(ts)] ${content}"
  fi
}

# One line per container: POD CONTAINER RESTARTS STATE TYPE
container_tpl='{{range .items}}{{$p := .metadata.name}}{{range .status.initContainerStatuses}}{{$p}} {{.name}} {{.restartCount}} {{if .state.running}}running{{else if .state.terminated}}terminated:{{.state.terminated.reason}}{{else if .state.waiting}}waiting:{{.state.waiting.reason}}{{end}} init{{"\n"}}{{end}}{{range .status.containerStatuses}}{{$p}} {{.name}} {{.restartCount}} {{if .state.running}}running{{else if .state.terminated}}terminated:{{.state.terminated.reason}}{{else if .state.waiting}}waiting:{{.state.waiting.reason}}{{end}} main{{"\n"}}{{end}}{{end}}'
pod_tpl='{{range .items}}{{.metadata.name}} {{.status.phase}}{{"\n"}}{{end}}'
cond_tpl='{{range .status.conditions}}{{.type}}={{.status}}{{if .reason}}({{.reason}}){{end}}{{"\n"}}{{end}}'
owner_tpl='{{range .items}}{{range .metadata.ownerReferences}}{{.name}}{{"\n"}}{{end}}{{end}}'
event_tpl='{{range .items}}{{.metadata.uid}}|{{.count}}|{{.lastTimestamp}}|{{.type}}|{{.reason}}|{{.involvedObject.kind}}/{{.involvedObject.name}}|{{.message}}{{"\n"}}{{end}}'

# Seconds between "repeated xN" summaries of an already printed event.
repeat_every=60

# Failed container attempts and blocking waits, one tab-separated line each:
# POD CONTAINER RESTARTS EXIT_CODE REASON WAITING_REASON DETAIL
# DETAIL is the last line of the termination message (what the process
# printed last, e.g. the storage-initializer error), shortened in the middle.
failure_py='
import json, re, sys
BLOCKING = {"ImagePullBackOff", "ErrImagePull", "InvalidImageName",
            "CreateContainerConfigError", "CreateContainerError", "RunContainerError"}
def short(s, n=320):
    s = " ".join(s.split())
    # Drop a leading "2026-11-19 20:31:39.667 1 storage.initializer ERROR [...]" prefix.
    s = re.sub(r"^\d{4}-\d\d-\d\d[ T][\d:.,]+\s+(\d+\s+)?(\S+\s+)?(ERROR|WARNING|CRITICAL|FATAL|INFO)\s+(\[[^\]]*\]\s+)?", "", s)
    # Python/urllib3 chains put the real reason last: keep "<message> | cause: <innermost cause>".
    if "Caused by " in s:
        head, cause = s.split(", last exception:")[0].split(" (Caused by ")[0], s.rsplit("Caused by ", 1)[1]
        cause = re.sub(r"\"\)+$", "", cause)
        cause = re.sub(r"^\w+\(\"?\w+\(host=[^)]*\):\s*", "", cause)
        cause += ")" * max(0, cause.count("(") - cause.count(")"))
        s = head[:140] + " | cause: " + cause
    return s if len(s) <= n else s[:110] + " ... " + s[-(n - 115):]
for pod in json.load(sys.stdin).get("items", []):
    st = pod.get("status") or {}
    for c in (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or []):
        state, last = c.get("state") or {}, c.get("lastState") or {}
        waiting = (state.get("waiting") or {})
        term = state.get("terminated") or last.get("terminated")
        fields = None
        if term and term.get("exitCode", 0) != 0:
            lines = [l for l in (term.get("message") or "").splitlines() if l.strip()]
            fields = [str(term.get("exitCode")), term.get("reason") or "Error",
                      waiting.get("reason", ""), short(lines[-1]) if lines else ""]
        elif waiting.get("reason") in BLOCKING:
            fields = ["", waiting["reason"], "", short(waiting.get("message", ""))]
        if fields:
            print("\t".join([pod["metadata"]["name"], c["name"], str(c.get("restartCount", 0))] + fields))
'

say ""
say "  ▶ Waiting for ${kind}/${name} in ${ns} (timeout ${timeout}s)"
say "    pods: ${selector}"

deadline=$(( $(date +%s) + timeout ))
ready=""
while :; do
  # --- the workload itself, Ready condition and non-True conditions ---
  if ! getout=$(kubectl get "$kind" "$name" -n "$ns" -o name 2>&1); then
    print_if_changed geterr "cannot read ${kind}/${name}: ${getout}"
  else
    print_if_changed geterr ""
  fi
  ready=$(kubectl get "$kind" "$name" -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  conds=$(kubectl get "$kind" "$name" -n "$ns" -o go-template="$cond_tpl" 2>/dev/null \
    | grep -v '=True' | tr '\n' ' ')
  print_if_changed conditions "$( [[ -n "$conds" ]] && printf '%s not ready: %s' "$name" "$conds")"

  # --- pods and container states ---
  containers=$(kubectl get pods -n "$ns" -l "$selector" -o go-template="$container_tpl" 2>/dev/null)
  pods=$(kubectl get pods -n "$ns" -l "$selector" -o go-template="$pod_tpl" 2>/dev/null)
  podview=""
  while read -r pod phase; do
    [[ -z "$pod" ]] && continue
    cs=$(awk -v p="$pod" '$1 == p { printf "%s%s=%s ", ($5 == "init" ? "init:" : ""), $2, $4 }' <<< "$containers")
    podview+="pod ${pod}: ${phase}  ${cs}"$'\n'
  done <<< "$pods"
  [[ -z "$podview" ]] && podview="no pods yet for ${selector}"
  podview=${podview%$'\n'}
  # Compare without timestamps so only real changes print; stamp on output.
  if [[ "$podview" != "$(cat "$state/pods" 2>/dev/null)" ]]; then
    printf '%s' "$podview" > "$state/pods"
    while IFS= read -r line; do
      [[ -n "$line" ]] && say "  [$(ts)] ${line}"
    done <<< "$podview"
  fi

  # --- new events for the workload, its pods and the ReplicaSets/Deployments
  #     owning them (exact names, so similarly named workloads don't leak in) ---
  owners=$(kubectl get pods -n "$ns" -l "$selector" -o go-template="$owner_tpl" 2>/dev/null)
  wanted=$( { echo "$name"; awk '{print $1}' <<< "$pods"; echo "$owners";
              sed -E 's/-[a-z0-9]{5,10}$//' <<< "$owners"; } | sort -u | tr '\n' ' ')
  # Each distinct event (object + reason + message) prints once; repeats are
  # only counted and summarized at most every repeat_every seconds, so a
  # noisy source (e.g. an HPA without metrics-server) does not bury the rest.
  now=$(date +%s)
  kubectl get events -n "$ns" -o go-template="$event_tpl" 2>/dev/null \
    | awk -F'|' -v w=" ${wanted}" '{ split($6, o, "/"); if (index(w, " " o[2] " ")) print }' \
    | while IFS='|' read -r uid count last type reason obj msg; do
        key="${uid}_${count}"
        [[ -e "$state/ev_${key}" ]] && continue
        : > "$state/ev_${key}"
        sig=$(printf '%s|%s|%s' "$obj" "$reason" "$msg" | cksum | awk '{print $1}')
        if [[ -e "$state/sig_${sig}" ]]; then
          read -r n since < "$state/sig_${sig}"
          echo "$(( n + 1 )) ${since}" > "$state/sig_${sig}"
        else
          echo "0 ${now}" > "$state/sig_${sig}"
          printf '%s %s %s' "$type" "$reason" "$obj" > "$state/sigdesc_${sig}"
          mark="·"; [[ "$type" == "Warning" ]] && mark="⚠"
          say "  [$(ts)] ${mark} event ${type} ${reason} ${obj}: ${msg}"
        fi
      done
  for f in "$state"/sig_*; do
    [[ -e "$f" ]] || continue
    read -r n since < "$f"
    if (( n > 0 && now - since >= repeat_every )); then
      say "  [$(ts)]   ↻ $(cat "${f/sig_/sigdesc_}") repeated ${n}x in the last $(( now - since ))s"
      echo "0 ${now}" > "$f"
    fi
  done

  # --- container failures: one highlighted line per failed attempt, with the
  #     exit code and the last line of the termination message ---
  kubectl get pods -n "$ns" -l "$selector" -o json 2>/dev/null | python3 -I -c "$failure_py" 2>/dev/null \
    | while IFS=$'\t' read -r pod container restarts code reason waiting detail; do
        key="fail_${pod}_${container}_${restarts}_${code}"
        [[ -e "$state/$key" ]] && continue
        : > "$state/$key"
        line="✘ ${pod}/${container} failed: ${reason}${code:+ (exit ${code})}, restarts ${restarts}${waiting:+, now ${waiting}}${detail:+ -> ${detail}}"
        printf '%s\n' "$line" > "$state/lastfail_${pod}_${container}"
        say "  [$(ts)] ${line}"
      done

  # --- follow logs of running/terminated containers, once per restart ---
  while read -r pod container restarts cstate _; do
    [[ -z "$pod" ]] && continue
    case "$cstate" in running|terminated*) ;; *) continue ;; esac
    key="log_${pod}_${container}_${restarts}"
    [[ -e "$state/$key" ]] && continue
    : > "$state/$key"
    say "  [$(ts)] --- logs ${pod}/${container} (restart ${restarts}) ---"
    # Process substitution so $! is kubectl itself (killing a pipeline's
    # last stage would leave `kubectl logs -f` running on quiet pods).
    kubectl logs -f -n "$ns" "$pod" -c "$container" --prefix=true \
      > >(awk '{ print "    │ " $0; fflush() }' > "$out") 2>&1 &
    followers+=($!)
  done <<< "$containers"

  if [[ "$ready" == "True" ]]; then
    sleep 1
    say "  ✔ ${kind}/${name} is Ready"
    say ""
    exit 0
  fi

  if (( $(date +%s) >= deadline )); then
    say "  ✘ ${kind}/${name} not Ready after ${timeout}s"
    if compgen -G "$state/lastfail_*" > /dev/null; then
      say "  --- container failures (most recent per container) ---"
      cat "$state"/lastfail_* | sed 's/^/    /' > "$out"
    fi
    say "  --- conditions ---"
    kubectl get "$kind" "$name" -n "$ns" -o go-template="$cond_tpl" 2>&1 | sed 's/^/    /' > "$out"
    while read -r pod _; do
      [[ -z "$pod" ]] && continue
      say "  --- describe pod ${pod} (tail) ---"
      kubectl describe pod -n "$ns" "$pod" 2>&1 | tail -n 25 | sed 's/^/    /' > "$out"
    done <<< "$pods"
    say ""
    exit 1
  fi
  sleep "$interval"
done