# Use a temporary alpine image to generate the manifest
FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS manifest
ARG VERSION
ARG TALOS_VERSION
RUN cat > /manifest.yaml <<EOF
version: v1alpha1
metadata:
  name: registry
  version: "${VERSION}-${TALOS_VERSION}"
  author: KimNorgaard
  description: |
    [extra] Provides a registry running on the host
  compatibility:
    talos:
      version: ">= v1.12.0"
EOF

# Grab the official image to cherry-pick the static binary and certificates
FROM ghcr.io/project-zot/zot-minimal:v2.1.15@sha256:346cefc8dd90c6ffe1e714460ba4bb5f867eacae9b40ca87da3c2e7e034ad31a AS dist

# Final stage: minimal image
FROM scratch
ARG TARGETARCH

# Copy the generated manifest
COPY --from=manifest /manifest.yaml /manifest.yaml
# Copy the extension service definition
COPY registry.yaml /rootfs/usr/local/etc/containers/registry.yaml
# zot-minimal is dynamically linked, so we need to copy the entire lib directory
COPY --from=dist /lib/ /rootfs/usr/local/lib/containers/registry/lib/
# Copy default zot config
COPY --from=dist /etc/zot/config.json /rootfs/usr/local/lib/containers/registry/etc/zot/config.json
# Copy the CA certificates
COPY --from=dist /etc/ssl/certs/ca-certificates.crt /rootfs/usr/local/lib/containers/registry/etc/ssl/certs/ca-certificates.crt
# Copy the zot binary
COPY --from=dist /usr/local/bin/zot-linux-${TARGETARCH}-minimal /rootfs/usr/local/lib/containers/registry/bin/zot
