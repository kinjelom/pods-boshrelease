#!/usr/bin/env bash
# Supervises one pod definition (the process monit watches):
#  - plays the Kubernetes YAML with `podman kube play --replace`,
#  - exits when a pod disappears or its infra container stops, so monit restarts the whole definition,
#  - follows container output into /var/vcap/sys/log/pods/<definition>/<container>.log,
#  - runs container healthchecks (livenessProbe/startupProbe): the static podman build has no systemd
#    support, so podman never schedules them itself,
#  - on SIGTERM tears the pods down with `podman kube down` (named volumes / PVC data are kept;
#    `kube play --wait` is not used on purpose: its teardown removes PVC volumes).
# podman commands are run in the background + `wait`, so the TERM trap is handled immediately; they are
# never killed on a timeout (a podman process killed while holding a lock leaks that lock).
set -uo pipefail

NAME=$1
source /var/vcap/jobs/pods/bin/pods-env.sh
pods_load_definition "$NAME" || exit 1

WORK_DIR="$PODS_RUN_DIR/$NAME.supervisor"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

declare -A FOLLOWERS=()    # container -> tail pid
declare -A HC_STARTUP=()   # container -> startupProbe interval (s), 0 = none
declare -A HC_LIVENESS=()  # container -> livenessProbe interval (s), 0 = none
declare -A HC_NEXT=()      # container -> next probe (epoch s)
declare -A HC_PID=()       # container -> running `podman healthcheck run` pid
CHILD_PID=""

function stop_followers() {
  local pid
  for pid in "${FOLLOWERS[@]}"; do
    kill -TERM "$pid" 2> /dev/null || true
  done
}

function shutdown() {
  log_info "stop requested, tearing down the pods of '$NAME'"
  # a pending `kube play` (e.g. pulling images) is interrupted, podman handles SIGTERM gracefully
  pid_alive "$CHILD_PID" && kill -TERM "$CHILD_PID" 2> /dev/null
  podman kube down "$PODS_KUBE_FILE" || log_warn "kube down of '$NAME' failed"
  stop_followers
  log_info "'$NAME' torn down"
  exit 0
}
trap shutdown TERM INT

# run_podman <output file|-> <args...>: runs podman interruptibly ("-": output goes to the supervisor
# logs), returns its exit code
function run_podman() {
  local out=$1
  shift
  if [[ "$out" == "-" ]]; then
    podman "$@" &
  else
    podman "$@" > "$out" 2>> "$PODS_LOG_DIR/supervisor.stderr.log" &
  fi
  CHILD_PID=$!
  wait "$CHILD_PID"
  local rc=$?
  CHILD_PID=""
  return $rc
}

# follow_logs <container>: copies the container's k8s-file log (CRI format: "<time> <stream> <F|P> <line>")
# to its BOSH log file. The k8s-file keeps its path for the whole life of the container (restart policy
# restarts included) and `tail -F` survives conmon's size-limit rotation, so no line is lost or duplicated.
# (`podman logs --follow` is not used: it ends on every container stop and loses lines when re-attached.)
function follow_logs() {
  local ctr=$1 path
  run_podman "$WORK_DIR/logpath" inspect "$ctr" --format '{{.HostConfig.LogConfig.Path}}' || return 0
  path=$(< "$WORK_DIR/logpath")
  [[ -n "$path" ]] || return 0
  tail -F -n +1 "$path" >> "$PODS_LOG_DIR/$ctr.log" 2>> "$PODS_LOG_DIR/supervisor.stderr.log" &
  FOLLOWERS[$ctr]=$!
}

# probe_seconds <podman interval seconds|"">: "" = no probe (0), 0 = podman's default interval (30s)
function probe_seconds() {
  [[ -n "$1" ]] || { echo 0; return; }
  awk '{ s = int($1 + 0.5); print (s > 0 ? s : 30) }' <<< "$1"
}

# register_healthcheck <container>: reads the startupProbe and livenessProbe intervals
function register_healthcheck() {
  local ctr=$1 startup liveness
  run_podman "$WORK_DIR/hc" inspect "$ctr" --format \
    '{{with .Config.StartupHealthCheck}}{{.Interval.Seconds}}{{end}}|{{with .Config.Healthcheck}}{{.Interval.Seconds}}{{end}}' || return 0
  IFS='|' read -r startup liveness < "$WORK_DIR/hc"
  HC_STARTUP[$ctr]=$(probe_seconds "$startup")
  HC_LIVENESS[$ctr]=$(probe_seconds "$liveness")
  HC_NEXT[$ctr]=$EPOCHSECONDS
  if ((HC_STARTUP[$ctr] + HC_LIVENESS[$ctr] > 0)); then
    log_info "probes of '$ctr': startup every ${HC_STARTUP[$ctr]}s, liveness every ${HC_LIVENESS[$ctr]}s (0 = none)"
  fi
}

# probe_interval <container> <podman status>: the startup probe interval until podman reports the container
# healthy (status "(starting)"), the liveness probe interval afterwards
function probe_interval() {
  if [[ "$2" == *"(starting)"* ]] && ((HC_STARTUP[$1] > 0)); then
    echo "${HC_STARTUP[$1]}"
  else
    echo "${HC_LIVENESS[$1]}"
  fi
}

# run_healthcheck <container> <interval>: `podman healthcheck run` runs the startup or liveness probe, updates
# the health status and applies the on-failure action (livenessProbe => restart); runs in the background so a
# slow probe does not block the supervisor
function run_healthcheck() {
  local ctr=$1
  pid_alive "${HC_PID[$ctr]:-}" && return 0
  podman healthcheck run "$ctr" > /dev/null 2>&1 &
  HC_PID[$ctr]=$!
  HC_NEXT[$ctr]=$((EPOCHSECONDS + $2))
}

# prepare_host_paths: creates hostPath directories (DirectoryOrCreate) and gives them to the user the containers
# run as (runAsUser/runAsGroup or host_path_owners). Runs before every play, so directories on the ephemeral disk
# are fixed after a VM recreate too; `chown -R` only runs when the directory's owner differs.
function prepare_host_paths() {
  local entry path owner create real prefix allowed
  for entry in "${HOST_PATH_OWNERS[@]}"; do
    IFS='|' read -r path owner create <<< "$entry"
    if [[ ! -e "$path" ]]; then
      [[ "$create" == "true" ]] || continue
      mkdir -p "$path"
    fi
    # resolve symlinks and check again that the real directory is below an allowed prefix
    real=$(realpath -e "$path") || continue
    allowed=false
    for prefix in "${HOST_PATH_PREFIXES[@]}"; do
      prefix=$(realpath -m "$prefix")
      [[ "$real" == "$prefix"/?* ]] && allowed=true
    done
    if [[ "$allowed" != "true" || ! -d "$real" ]]; then
      log_warn "hostPath $path ($real) is not a directory below ${HOST_PATH_PREFIXES[*]}, ownership left unchanged"
      continue
    fi
    if [[ "$(stat -c %u:%g "$real")" != "$owner" ]]; then
      log_info "hostPath $path: chown -R $owner"
      chown -R "$owner" "$real" || log_error "chown -R $owner $real failed"
    fi
  done
}

prepare_host_paths

log_info "playing $PODS_KUBE_FILE (pods: ${POD_NAMES[*]})"
if ! run_podman - kube play --replace --log-driver k8s-file "${PLAY_FLAGS[@]}" "$PODS_KUBE_FILE"; then
  log_error "podman kube play failed, monit will retry"
  exit 1
fi
log_info "pods of '$NAME' created"

while true; do
  for pod in "${POD_NAMES[@]}"; do
    run_podman "$WORK_DIR/ps" ps --all --filter "pod=$pod" --format '{{.Names}}|{{.IsInfra}}|{{.State}}|{{.Status}}' || continue

    if ! grep -q '|true|running|' "$WORK_DIR/ps"; then
      log_error "pod '$pod' is gone or stopped ($(tr '\n' ' ' < "$WORK_DIR/ps")), exiting so that monit restarts '$NAME'"
      stop_followers
      exit 1
    fi

    while IFS='|' read -r ctr infra state status; do
      [[ -z "$ctr" || "$infra" == "true" ]] && continue
      if [[ "$FOLLOW_LOGS" == "true" ]] && ! pid_alive "${FOLLOWERS[$ctr]:-}"; then
        follow_logs "$ctr"
      fi
      [[ -n "${HC_STARTUP[$ctr]:-}" ]] || register_healthcheck "$ctr"
      [[ -n "${HC_STARTUP[$ctr]:-}" ]] || continue # inspect failed, retried on the next poll
      interval=$(probe_interval "$ctr" "$status")
      if ((interval > 0)) && [[ "$state" == "running" ]] && ((EPOCHSECONDS >= HC_NEXT[$ctr])); then
        run_healthcheck "$ctr" "$interval"
      fi
    done < "$WORK_DIR/ps"
  done

  # interruptible sleep (the TERM trap runs immediately)
  sleep "$POLL_INTERVAL" &
  wait $!
done
