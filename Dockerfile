# Use a temporary alpine image to generate the manifest
FROM alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS manifest
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
FROM ghcr.io/project-zot/zot:v2.1.20@sha256:542e25be4d32e7879c0cfad93492a93c81b1e059cbd2d30d485d4bd567318234 AS dist

# Intermediate stage to normalize library paths across architectures
FROM alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS normalizer
COPY --from=dist / /dist/
RUN mkdir -p /normalized/lib /normalized/lib64 && \
    cp -a /dist/lib/. /normalized/lib/ && \
    if [ -d "/dist/lib64" ]; then cp -a /dist/lib64/. /normalized/lib64/; fi

# Final stage: image
FROM scratch
ARG TARGETARCH

# Copy the generated manifest
COPY --from=manifest /manifest.yaml /manifest.yaml
# Copy the extension service definition
COPY registry.yaml /rootfs/usr/local/etc/containers/registry.yaml
# zot is dynamically linked, so we need to copy the normalized lib directories
COPY --from=normalizer /normalized/lib/ /rootfs/usr/local/lib/containers/registry/lib/
COPY --from=normalizer /normalized/lib64/ /rootfs/usr/local/lib/containers/registry/lib64/
# Copy default zot config
COPY --from=dist /etc/zot/config.json /rootfs/usr/local/lib/containers/registry/etc/zot/config.json
# Copy the CA certificates
COPY --from=dist /etc/ssl/certs/ca-certificates.crt /rootfs/usr/local/lib/containers/registry/etc/ssl/certs/ca-certificates.crt
# Copy the zot binary
COPY --from=dist /usr/local/bin/zot-linux-${TARGETARCH} /rootfs/usr/local/lib/containers/registry/bin/zot
