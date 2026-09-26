#!/usr/bin/env bash
# Environment for podman invocations (sourced by BOSH scripts and the operator shell profile).
# Engine configuration itself is linked into /etc/containers by the podman job pre-start.

export PATH="/var/vcap/packages/podman/bin:${PATH}"
export REGISTRY_AUTH_FILE=/var/vcap/jobs/podman/config/auth.json
