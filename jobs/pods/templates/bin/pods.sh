#!/usr/bin/env bash
# Operator command for the pod definitions of this VM (/usr/local/bin/pods; `bosh ssh`, `sudo -i`, `pods`):
# kubectl-like views of the definitions, their pods and containers on top of podman, monit and the job's files.
set -euo pipefail

MONIT=/var/vcap/bosh/bin/monit

function usage() {
  cat << 'EOF'
Usage: pods [command] [definition] [options]

  list                                    definitions, their monit process, pods and containers (default)
  ps       <definition> [podman ps flags] containers of the definition's pods
  logs     <definition> [-c <container>] [podman logs flags, e.g. -f, --tail 100, --since 10m]
  exec     <definition> [-c <container>] [-- <command> [args...]]   (default command: sh)
  describe <definition>                   settings, files, pods and containers
  egress   <definition> [<lines>]         egress rules with their counters and the end of egress.log
  restart  <definition>                   monit restart pod-<definition>
  kube     <definition>                   the rendered Kubernetes YAML (may contain Secrets)
  completion bash                         bash completion (loaded by /etc/profile.d/pods-bosh.sh)

<container>: the name from the manifest (or podman's <pod>-<container>); optional when only one container runs.
EOF
}

function die() {
  echo "pods: $*" >&2
  exit 1
}

function definitions() {
  local dir
  for dir in "$PODS_DEFS_DIR"/*/; do
    [[ -f "$dir/definition.env" ]] && basename "$dir"
  done
  return 0
}

# load <definition>: POD_NAMES, PODS_KUBE_FILE, PODS_LOG_DIR, EGRESS_*, ... of the definition
function load() {
  [[ -n "${1:-}" ]] || die "definition missing, one of: $(definitions | paste -sd ' ')"
  [[ -f "$PODS_DEFS_DIR/$1/definition.env" ]] || die "unknown definition '$1', one of: $(definitions | paste -sd ' ')"
  pods_load_definition "$1"
}

function monit_state() {
  "$MONIT" summary 2> /dev/null | awk -F"'" -v process="pod-$1" '$2 == process { s = $3; gsub(/^[ \t]+|[ \t]+$/, "", s); print s }'
}

# table: aligns "|"-separated columns
function table() {
  awk -F'|' '{ for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > width[i]) width[i] = length($i) } cells[NR] = NF }
    END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i < cells[r]; i++) line = line sprintf("%-" (width[i] + 2) "s", cell[r, i]); print line cell[r, cells[r]] } }'
}

# container <name|"">: the podman name of a (non-infra) container of the loaded definition's pods; without a
# name the only running one
function container() {
  local wanted=$1 pod name infra state all=() matches=()
  for pod in "${POD_NAMES[@]}"; do
    while IFS='|' read -r name infra state; do
      [[ -n "$name" && "$infra" != "true" ]] || continue
      all+=("$name")
      if [[ -z "$wanted" && "$state" == "running" ]] || [[ -n "$wanted" && ("$name" == "$wanted" || "$name" == "$pod-$wanted") ]]; then
        matches+=("$name")
      fi
    done < <(podman ps --all --filter "pod=$pod" --format '{{.Names}}|{{.IsInfra}}|{{.State}}')
  done
  if ((${#matches[@]} == 1)); then
    echo "${matches[0]}"
    return 0
  fi
  ((${#all[@]} > 0)) || die "definition '$PODS_DEF_NAME' has no containers (pods: ${POD_NAMES[*]})"
  if [[ -n "$wanted" ]]; then
    die "no container '$wanted' in definition '$PODS_DEF_NAME', containers: ${all[*]}"
  fi
  die "choose a container of definition '$PODS_DEF_NAME' with -c: ${all[*]}"
}

function pod_filters() {
  local pod
  for pod in "${POD_NAMES[@]}"; do
    printf '%s\n' --filter "pod=$pod"
  done
}

function cmd_list() {
  local def state pod rows
  {
    echo "DEFINITION|MONIT|POD|CONTAINER|STATE|STATUS"
    for def in $(definitions); do
      (
        load "$def"
        state=$(monit_state "$def")
        for pod in "${POD_NAMES[@]}"; do
          rows=$(podman ps --all --filter "pod=$pod" --format '{{.Names}}|{{.IsInfra}}|{{.State}}|{{.Status}}' |
            awk -F'|' -v prefix="$def|${state:--}|$pod" '$2 != "true" { print prefix "|" $1 "|" $3 "|" $4 }')
          echo "${rows:-$def|${state:--}|$pod|-|-|-}"
        done
      )
    done
  } | table
  [[ -n "$(definitions)" ]] || echo "(no pod definitions on this VM)"
}

function cmd_describe() {
  local pod filters
  mapfile -t filters < <(pod_filters)
  echo "Definition:  $PODS_DEF_NAME (monit: pod-$PODS_DEF_NAME $(monit_state "$PODS_DEF_NAME"))"
  echo "Pods:        ${POD_NAMES[*]}"
  echo "Kube YAML:   $PODS_KUBE_FILE"
  echo "Logs:        $PODS_LOG_DIR/"
  echo "Timeouts:    start ${START_TIMEOUT}s, stop ${STOP_TIMEOUT}s; wait_healthy: $WAIT_HEALTHY, follow_logs: $FOLLOW_LOGS"
  echo "Play flags:  ${PLAY_FLAGS[*]:-(none)}"
  if [[ -n "$EGRESS_RULES" ]]; then
    echo "Egress:      restricted (DNS: $EGRESS_DNS, connection log: $EGRESS_LOG), see: pods egress $PODS_DEF_NAME"
  else
    echo "Egress:      unrestricted"
  fi
  echo
  podman ps --all --pod "${filters[@]}" --format '{{.Names}}|{{.PodName}}|{{.State}}|{{.Status}}|{{.Image}}' |
    { echo "CONTAINER|POD|STATE|STATUS|IMAGE"; cat; } | table
}

function cmd_egress() {
  local pod pid
  if [[ -z "$EGRESS_RULES" ]]; then
    echo "definition '$PODS_DEF_NAME' has no egress rules: outbound traffic is not restricted"
    return 0
  fi
  for pod in "${POD_NAMES[@]}"; do
    pid=$(podman ps --filter "pod=$pod" --format '{{.IsInfra}} {{.Pid}}' | awk '$1 == "true" { print $2 }')
    echo "=== pod $pod (infra pid ${pid:-none: not running})"
    # the log sets hold the connections since the supervisor's last poll
    [[ -z "$pid" ]] || nsenter --target "$pid" --net nft list table inet pods_egress
  done
  echo "=== $PODS_LOG_DIR/egress.log (connection log: $EGRESS_LOG)"
  tail -n "${1:-20}" "$PODS_LOG_DIR/egress.log" 2> /dev/null || echo "(no entries)"
}

function completion_bash() {
  cat << 'EOF'
_pods_complete() {
  local commands="list ps logs exec describe egress restart kube completion help"
  if ((COMP_CWORD == 1)); then
    COMPREPLY=($(compgen -W "$commands" -- "${COMP_WORDS[1]}"))
  elif ((COMP_CWORD == 2)) && [[ " list completion help " != *" ${COMP_WORDS[1]} "* ]]; then
    COMPREPLY=($(compgen -W "$(ls /var/vcap/data/pods/definitions 2> /dev/null)" -- "${COMP_WORDS[2]}"))
  fi
}
complete -F _pods_complete pods
EOF
}

COMMAND=${1:-list}
(($# == 0)) || shift
case "$COMMAND" in
  help | -h | --help) usage; exit 0 ;;
  completion) [[ "${1:-}" == "bash" ]] || die "usage: pods completion bash"; completion_bash; exit 0 ;;
esac
((EUID == 0)) || die "run as root (sudo -i)"
source /var/vcap/jobs/pods/bin/pods-env.sh

case "$COMMAND" in
  list) cmd_list ;;
  ps)
    load "${1:-}"
    shift
    mapfile -t filters < <(pod_filters)
    exec podman ps --all --pod "${filters[@]}" "$@"
    ;;
  logs)
    load "${1:-}"
    shift
    wanted="" args=()
    while (($#)); do
      case "$1" in
        -c | --container) wanted=${2:-}; shift 2 || die "-c needs a container name" ;;
        *) args+=("$1"); shift ;;
      esac
    done
    ctr=$(container "$wanted")
    exec podman logs "${args[@]}" "$ctr"
    ;;
  exec)
    load "${1:-}"
    shift
    wanted=""
    while (($#)); do
      case "$1" in
        -c | --container) wanted=${2:-}; shift 2 || die "-c needs a container name" ;;
        --) shift; break ;;
        *) die "usage: pods exec <definition> [-c <container>] [-- <command> [args...]]" ;;
      esac
    done
    (($#)) || set -- sh
    flags=(-i)
    if [[ -t 0 && -t 1 ]]; then flags=(-it); fi
    ctr=$(container "$wanted")
    exec podman exec "${flags[@]}" "$ctr" "$@"
    ;;
  describe) load "${1:-}"; cmd_describe ;;
  egress) load "${1:-}"; cmd_egress "${2:-}" ;;
  restart)
    load "${1:-}"
    "$MONIT" restart "pod-$PODS_DEF_NAME"
    echo "monit restart of pod-$PODS_DEF_NAME requested, follow it with: pods list"
    ;;
  kube) load "${1:-}"; cat "$PODS_KUBE_FILE" ;;
  *) usage >&2; exit 1 ;;
esac
