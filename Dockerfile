# Use a temporary alpine image to generate the manifest
FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS manifest
ARG VERSION
ARG TALOS_VERSION
RUN cat > /manifest.yaml <<EOF
version: v1alpha1
metadata:
  name: registry
  version: "${VERSION}-${TALOS_VERSION}"
  author: Netic
  description: |
    [extra] Provides a registry running on the host
  compatibility:
    talos:
      version: ">= v1.13.0"
EOF

# Grab the official image to cherry-pick the static binary and certificates
FROM ghcr.io/project-zot/zot-minimal:v2.1.15@sha256:346cefc8dd90c6ffe1e714460ba4bb5f867eacae9b40ca87da3c2e7e034ad31a AS dist

# Get static busybox
FROM busybox:stable-musl AS busybox

# Intermediate stage to normalize library paths and setup busybox/script
FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS builder
COPY --from=dist / /dist/
RUN mkdir -p /normalized/lib /normalized/lib64 && \
    cp -a /dist/lib/. /normalized/lib/ && \
    if [ -d "/dist/lib64" ]; then cp -a /dist/lib64/. /normalized/lib64/; fi

# Setup rootfs structure for the service
RUN mkdir -p /rootfs/bin
COPY --from=busybox /bin/busybox /rootfs/bin/busybox
RUN for tool in sh wget kill sleep echo grep sed head; do \
        ln -s busybox /rootfs/bin/$tool; \
    done

# Copy and prepare the startup script
COPY scripts/zot-start.sh /rootfs/bin/zot-start.sh
RUN chmod +x /rootfs/bin/zot-start.sh

# Final stage: minimal image
FROM scratch
ARG TARGETARCH

# Copy the generated manifest
COPY --from=manifest /manifest.yaml /manifest.yaml
# Copy the extension service definition
COPY registry.yaml /rootfs/usr/local/etc/containers/registry.yaml

# Base path for the service container
ARG SERVICE_ROOT=/rootfs/usr/local/lib/containers/registry

# Copy busybox and symlinks
COPY --from=builder /rootfs/bin/ ${SERVICE_ROOT}/bin/

# zot-minimal is dynamically linked, so we need to copy the normalized lib directories
COPY --from=builder /normalized/lib/ ${SERVICE_ROOT}/lib/
COPY --from=builder /normalized/lib64/ ${SERVICE_ROOT}/lib64/
# Copy default zot config
COPY --from=dist /etc/zot/config.json ${SERVICE_ROOT}/etc/zot/config.json
# Copy the CA certificates
COPY --from=dist /etc/ssl/certs/ca-certificates.crt ${SERVICE_ROOT}/etc/ssl/certs/ca-certificates.crt
# Copy the zot binary
COPY --from=dist /usr/local/bin/zot-linux-${TARGETARCH}-minimal ${SERVICE_ROOT}/bin/zot
