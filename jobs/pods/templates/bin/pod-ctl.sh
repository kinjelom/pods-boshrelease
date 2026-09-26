#!/usr/bin/env bash
# monit start/stop program of one pod definition: pod-ctl {start|stop} <definition>
set -euo pipefail

ACTION=${1:-}
NAME=${2:-}
if [[ -z "$ACTION" || -z "$NAME" ]]; then
  echo "Usage: $0 {start|stop} <definition>" >&2
  exit 1
fi

source /var/vcap/jobs/pods/bin/pods-env.sh
pods_load_definition "$NAME"

mkdir -p "$PODS_RUN_DIR" "$PODS_LOG_DIR"
exec 1>> "$PODS_LOG_DIR/pod-ctl.stdout.log"
exec 2>> "$PODS_LOG_DIR/pod-ctl.stderr.log"

case "$ACTION" in
  start)
    if pid_alive "$(cat "$PODS_PID_FILE" 2> /dev/null || true)"; then
      log_info "supervisor of '$NAME' is already running"
      exit 0
    fi
    log_info "starting supervisor of '$NAME'"
    # own session (pgid = pid): a forced stop can kill the supervisor together with its log followers
    setsid "$PODS_JOB_DIR/bin/pod-supervisor" "$NAME" \
      >> "$PODS_LOG_DIR/supervisor.stdout.log" 2>> "$PODS_LOG_DIR/supervisor.stderr.log" < /dev/null &
    echo $! > "$PODS_PID_FILE"
    ;;

  stop)
    pid=$(cat "$PODS_PID_FILE" 2> /dev/null || true)
    if pid_alive "$pid"; then
      log_info "stopping supervisor of '$NAME' (pid $pid)"
      kill -TERM "$pid"
      for ((i = 0; i < STOP_TIMEOUT + 15; i++)); do
        pid_alive "$pid" || break
        sleep 1
      done
      if pid_alive "$pid"; then
        log_warn "supervisor of '$NAME' did not stop in time, killing its process group"
        kill -KILL -- "-$pid" 2> /dev/null || kill -KILL "$pid" || true
      fi
    fi
    # idempotent safety net; named volumes (PVC) are never removed
    podman kube down "$PODS_KUBE_FILE" > /dev/null 2>&1 || true
    rm -f "$PODS_PID_FILE"
    log_info "'$NAME' stopped"
    ;;

  *)
    echo "Usage: $0 {start|stop} <definition>" >&2
    exit 1
    ;;
esac
