#!/bin/bash

set -eux

source ./src/meta-info/blobs-versions.env
source ./rel.env
unset BOSH_ALL_PROXY

mkdir -p "$TMP_DIR"

function down_add_blob {
  BLOBS_GROUP=$1
  FILE=$2
  URL=$3
  if [ ! -f "blobs/${BLOBS_GROUP}/${FILE}" ];then
    echo "Downloads resource from the Internet ($URL -> $TMP_DIR/$FILE)"
    curl -L "$URL" --output "$TMP_DIR/$FILE"
    echo "Adds blob ($TMP_DIR/$FILE -> $BLOBS_GROUP/$FILE), starts tracking blob in config/blobs.yml for inclusion in packages"
    bosh add-blob "$TMP_DIR/$FILE" "$BLOBS_GROUP/$FILE"
  fi
}

down_add_blob "podman" "podman-static-${PODMAN_STATIC_VERSION}-linux-amd64.tar.gz" "$PODMAN_STATIC_URL"
down_add_blob "podman-exporter" "prometheus-podman-exporter-${PODMAN_EXPORTER_VERSION}.src.tar.gz" "$PODMAN_EXPORTER_URL"

echo "Download blobs into blobs/ based on config/blobs.yml"
bosh sync-blobs

echo "Upload previously added blobs that were not yet uploaded to the blobstore. Updates config/blobs.yml with returned blobstore IDs."
bosh upload-blobs
