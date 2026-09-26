#!/usr/bin/env bash
# podman wrapper with the BOSH job environment, e.g.: /var/vcap/jobs/podman/bin/podman ps --pod

source /var/vcap/jobs/podman/bin/podman-env.sh
exec /var/vcap/packages/podman/bin/podman "$@"
