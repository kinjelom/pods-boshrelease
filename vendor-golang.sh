#!/bin/bash

# requires an up-to-date clone of https://github.com/cloudfoundry/bosh-package-golang-release
unset BOSH_ALL_PROXY
bosh vendor-package golang-1.27-linux ../../../bosh-packages/bosh-package-golang-release
