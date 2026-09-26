#!/bin/bash

function assert_declared_variables() {
  for var in "$@"; do
    if [ -z "${!var+x}" ]; then
      echo "Error: variable $var is not declared!"
      exit 1
    fi
  done
}

function log_info() {
  local timestamp
  timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
  printf "[%s] INFO %s\n" "$timestamp" "$*"
}

function log_warn() {
  local timestamp
  timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
  printf "[%s] WARN %s\n" "$timestamp" "$*"
}

function log_error() {
  local timestamp
  timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
  printf "[%s] ERROR %s\n" "$timestamp" "$*" >&2
}

function log_debug() {
  if [[ "${ENABLE_DEBUG_LOG:-false}" == "true" ]]; then
    local timestamp
    timestamp=$(date +"%Y-%m-%dT%H:%M:%S%z")
    printf "[%s] DEBUG %s\n" "$timestamp" "$*"
  fi
}
