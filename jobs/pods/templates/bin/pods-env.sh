#!/usr/bin/env bash
# Common paths and helpers of the pods job (sourced by pre-start, post-start, pod-ctl and pod-supervisor).

export PODS_JOB_DIR=/var/vcap/jobs/pods
export PODS_RUN_DIR=/var/vcap/sys/run/pods
export PODS_LOG_ROOT=/var/vcap/sys/log/pods
export PODS_DEFS_DIR=/var/vcap/data/pods/definitions

source /var/vcap/jobs/podman/bin/podman-env.sh
source /var/vcap/packages/common/script_utils.sh

# pods_load_definition <name>: sets PODS_DEF_* paths and sources definition.env
# (POD_NAMES, PLAY_FLAGS, FOLLOW_LOGS, WAIT_HEALTHY, START_TIMEOUT, STOP_TIMEOUT, POLL_INTERVAL)
function pods_load_definition() {
  PODS_DEF_NAME=$1
  PODS_DEF_DIR="$PODS_DEFS_DIR/$1"
  PODS_KUBE_FILE="$PODS_DEF_DIR/kube.yml"
  PODS_LOG_DIR="$PODS_LOG_ROOT/$1"
  PODS_PID_FILE="$PODS_RUN_DIR/$1.pid"
  if [[ ! -f "$PODS_DEF_DIR/definition.env" ]]; then
    log_error "unknown pod definition '$1' ($PODS_DEF_DIR/definition.env is missing)"
    return 1
  fi
  source "$PODS_DEF_DIR/definition.env"
}

function pid_alive() {
  [[ -n "${1:-}" ]] && kill -0 "$1" 2> /dev/null
}

# pods_containers <pod>: one line per container: "<name>|<is infra>|<state>|<status>|<healthcheck interval s>"
# `podman ps` is used instead of `podman pod inspect` on purpose: pod inspect holds the pod lock while
# taking container locks, which can deadlock with podman's own restart handling of crash-looping containers.
function pods_containers() {
  podman ps --all --filter "pod=$1" \
    --format '{{.Names}}|{{.IsInfra}}|{{.State}}|{{.Status}}' 2> /dev/null
}

# pods_ready <pod> <wait_healthy>: all containers running and (optionally) none starting/unhealthy
function pods_ready() {
  local name infra state status count=0
  while IFS='|' read -r name infra state status; do
    [[ -n "$name" ]] || continue
    count=$((count + 1))
    [[ "$state" == "running" ]] || return 1
    if [[ "$2" == "true" && "$status" =~ \((starting|unhealthy)\) ]]; then
      return 1
    fi
  done < <(pods_containers "$1")
  ((count > 0))
}
