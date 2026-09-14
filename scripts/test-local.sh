#!/usr/bin/env bash
set -euo pipefail

TALOS_VERSION=${TALOS_VERSION:?TALOS_VERSION must be set}

# TALOS_VERSION is a series (e.g. v1.14) so the extension isn't rebuilt for every
# patch release, but release artifacts (UKI, ISO, ...) are published per patch.
# Resolve the newest vX.Y.Z tag in that series unless one is given explicitly.
if [ -z "${TALOS_RELEASE:-}" ]; then
    if [[ "$TALOS_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        TALOS_RELEASE="$TALOS_VERSION"
    else
        SERIES="${TALOS_VERSION#v}"
        TALOS_RELEASE=$(git ls-remote --refs --tags https://github.com/siderolabs/talos.git "v${SERIES}.*" |
            awk '{print $2}' |
            grep -E "^refs/tags/v${SERIES//./\\.}\.[0-9]+$" |
            sed 's|refs/tags/||' |
            sort -V -u |
            tail -1)
        if [ -z "$TALOS_RELEASE" ]; then
            echo "Could not resolve a released patch version for Talos $TALOS_VERSION"
            exit 1
        fi
        echo "Resolved Talos $TALOS_VERSION to latest release $TALOS_RELEASE"
    fi
fi
UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
IMAGE_URL="ttl.sh/${UUID}/talos-registry-extension"
TAG="2h"
CIDR=${CIDR:-192.168.1.0/24}
ENDPOINT="${ENDPOINT:-192.168.1.2}"
# The provisioner's own DNS forwarder on the cluster gateway does not come up on
# macOS, leaving the node unable to resolve ttl.sh and so unable to pull the
# installer. Hand the node resolvers it can reach through the vmnet NAT instead.
NAMESERVERS="${NAMESERVERS:-1.1.1.1,8.8.8.8}"

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
    --build-arg VERSION="dev" \
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
    ghcr.io/siderolabs/imager:$TALOS_RELEASE installer \
    --arch "$PLATARCH" \
    --system-extension-image "$IMAGE_URL:$TAG"

INSTALLER_TAR="build/installer-${PLATARCH}.tar"
echo "==> Loading and pushing custom installer image"
LOAD_OUTPUT=$(docker load -i "$INSTALLER_TAR")
TALOS_IMAGE=$(echo "$LOAD_OUTPUT" | grep "Loaded image" | awk '{print $3}')
INSTALLER_IMAGE="ttl.sh/${UUID}/talos-installer:$TAG"
docker tag "$TALOS_IMAGE" "$INSTALLER_IMAGE"
docker push "$INSTALLER_IMAGE"

echo "===> Pushed: $INSTALLER_IMAGE"

CLUSTER_NAME="reg-test"

# NOTE: do not set cluster.allowSchedulingOnControlPlanes here -- Talos 1.14+
# emits a KubeNodeConfig document carrying the control-plane taint and rejects
# the legacy v1alpha1 field alongside it. This test never schedules a pod.
cat <<EOF > build/patch.yaml
machine:
  files:
    - op: create
      path: /var/mnt/zot-registry/.keep
      permissions: 0644
      content: ""
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: registry
configFiles:
  - mountPath: /etc/zot/config.json
    content: |
      {
        "storage": {
          "rootDirectory": "/var/lib/registry",
          "dedupe": true,
          "gc": true,
          "gcInterval": "24h"
        },
        "http": {
          "address": "0.0.0.0",
          "port": "5001",
          "compat": ["docker2s2"]
        },
        "log": {
          "level": "debug"
        }
      }
EOF

# The provisioner's processes are detached and outlive this script, so a failure
# anywhere below would otherwise leak a running cluster. Trap from here on.
cleanup() {
    local rc=$?
    if [ "${CLEANUP:-true}" = "true" ]; then
        echo "==> Cleaning up..."
        sudo -E talosctl cluster destroy --name "$CLUSTER_NAME" || true
        rm -rf build/
    else
        echo "==> Skipping cleanup."
        echo "To clean up manually, run:"
        echo "  sudo talosctl cluster destroy --name $CLUSTER_NAME"
        echo "  rm -rf build/"
    fi
    return $rc
}
trap cleanup EXIT

echo "==> Creating Talos dev (QEMU) cluster ($CLUSTER_NAME)"
sudo -E talosctl cluster create dev \
    --name "$CLUSTER_NAME" \
    --cidr "$CIDR" \
    --nameservers "$NAMESERVERS" \
    --arch "$PLATARCH" \
    --uki-path "https://github.com/siderolabs/talos/releases/download/${TALOS_RELEASE}/metal-${PLATARCH}-uki.efi" \
    --install-image "$INSTALLER_IMAGE" \
    --controlplanes 1 \
    --workers 0 \
    --config-patch-control-plane @build/patch.yaml

sudo chown -R $(id -u):$(id -g) ${HOME}/.talos

TALOSCONFIG="${HOME}/.talos/config"

talosctl --talosconfig "$TALOSCONFIG" config endpoint $ENDPOINT
talosctl --talosconfig "$TALOSCONFIG" config node $ENDPOINT

echo "==> Waiting for extension service 'ext-registry' to be Running..."
set +e
for i in {1..30}; do
    # When an extension is loaded by Talos, it prefixes the service name with `ext-`
    STATE=$(talosctl --talosconfig "$TALOSCONFIG" get service ext-registry -o json | jq '.spec.running // "unknown"')
    if [ "$STATE" = "true" ]; then
        echo "Service is Running!"
        break
    fi
    sleep 5
done
set -e

echo "==> Testing the registry endpoint via HTTP on node $ENDPOINT"
if curl -s http://$ENDPOINT:5001/v2/ > /dev/null; then
    echo -e "\nSUCCESS: Registry responded on http://$ENDPOINT:5001/v2/"
else
    echo -e "\nFAILED: Registry did not respond as expected."
    talosctl --talosconfig "$TALOSCONFIG" service ext-registry || true
    talosctl --talosconfig "$TALOSCONFIG" logs ext-registry || true
    exit 1
fi

echo "==> DONE"
