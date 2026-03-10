#!/usr/bin/env bash
set -euo pipefail

TALOS_VERSION=${TALOS_VERSION:-v1.12.4}
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
IMAGE_URL="ttl.sh/${UUID}/talos-registry-extension"
TAG="2h"

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    PLATARCH="amd64"
    PLATFORM="linux/amd64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    PLATARCH="arm64"
    PLATFORM="linux/arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

echo "==> Building and pushing extension to ephemeral registry ($IMAGE_URL:$TAG)"
docker buildx build --platform "$PLATFORM" \
    --build-arg VERSION="0.1.0" \
    --build-arg TALOS_VERSION="$TALOS_VERSION" \
    -t "$IMAGE_URL:$TAG" \
    --push .

mkdir -p build

# Ensure DOCKER_HOST is set so tools can find the docker daemon (e.g. for Colima)
if [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
    echo "Discovered DOCKER_HOST=$DOCKER_HOST from docker context"
fi

echo "==> Building custom Talos installer image with the extension"
docker run --rm -t -v "$PWD/build:/out" \
    ghcr.io/siderolabs/imager:$TALOS_VERSION installer \
    --arch "$PLATARCH" \
    --system-extension-image "$IMAGE_URL:$TAG"

INSTALLER_TAR="build/installer-${PLATARCH}.tar"
echo "==> Loading and pushing custom installer image"
LOAD_OUTPUT=$(docker load -i "$INSTALLER_TAR")
TALOS_IMAGE=$(echo "$LOAD_OUTPUT" | grep "Loaded image" | awk '{print $3}')
INSTALLER_IMAGE="ttl.sh/${UUID}/talos-installer:$TAG"
docker tag "$TALOS_IMAGE" "$INSTALLER_IMAGE"
docker push "$INSTALLER_IMAGE"

CLUSTER_NAME="reg-test"

cat <<EOF > build/patch.yaml
cluster:
  allowSchedulingOnControlPlanes: true
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: registry
configFiles:
  - mountPath: /etc/distribution/config.yml
    content: |
      version: 0.1
      log:
        fields:
          service: registry
      storage:
        cache:
          blobdescriptor: inmemory
        filesystem:
          rootdirectory: /var/lib/registry
      http:
        addr: :5001
        headers:
          X-Content-Type-Options: [nosniff]
      health:
        storagedriver:
          enabled: true
          interval: 10s
          threshold: 3
EOF

echo "==> Creating Talos dev (QEMU) cluster ($CLUSTER_NAME)"
sudo -E talosctl cluster create dev \
    --name "$CLUSTER_NAME" \
    --cidr "192.168.1.0/24" \
    --arch "$PLATARCH" \
    --uki-path "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-${PLATARCH}-uki.efi" \
    --install-image "$INSTALLER_IMAGE" \
    --controlplanes 1 \
    --workers 0 \
    --config-patch-control-plane @build/patch.yaml

sudo chown -R $(id -u):$(id -g) ${HOME}/.talos

sudo talosctl config nodes 10.5.0.2

echo "==> Waiting for extension service 'ext-registry' to be Running..."
set +e
for i in {1..30}; do
    # When an extension is loaded by Talos, it prefixes the service name with `ext-`
    STATE=$(sudo talosctl get service ext-registry -o json | jq '.spec.running // "unknown"')
    if [ "$STATE" = "true" ]; then
        echo "Service is Running!"
        break
    fi
    sleep 5
done
set -e

echo "==> Testing the registry endpoint via HTTP on node 10.5.0.2"
if curl -s http://10.5.0.2:5001/v2/ > /dev/null; then
    echo -e "\nSUCCESS: Registry responded on http://10.5.0.2:5001/v2/"
else
    echo -e "\nFAILED: Registry did not respond as expected."
    sudo talosctl service ext-registry || true
    sudo talosctl logs ext-registry || true
    exit 1
fi

if [ "${CLEANUP:-true}" = "true" ]; then
    echo "==> Cleaning up..."
    sudo talosctl cluster destroy --name "$CLUSTER_NAME"
    rm -rf build/
fi

echo "==> DONE"
