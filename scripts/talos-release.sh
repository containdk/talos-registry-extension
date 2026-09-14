#!/usr/bin/env bash
# Resolve a Talos version series (e.g. v1.14) to the newest patch release in it.
#
# The extension is built per series so it isn't rebuilt for every patch, but
# release artifacts (talosctl, UKI, ISO, imager) are published per patch. A
# version that already names a patch is echoed back unchanged.
set -euo pipefail

VERSION=${1:?usage: talos-release.sh <talos-version>}

if [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "$VERSION"
    exit 0
fi

SERIES="${VERSION#v}"
RELEASE=$(git ls-remote --refs --tags https://github.com/siderolabs/talos.git "v${SERIES}.*" |
    awk '{print $2}' |
    grep -E "^refs/tags/v${SERIES//./\\.}\.[0-9]+$" |
    sed 's|refs/tags/||' |
    sort -V -u |
    tail -1)

if [ -z "$RELEASE" ]; then
    echo "Could not resolve a released patch version for Talos $VERSION" >&2
    exit 1
fi

echo "$RELEASE"
