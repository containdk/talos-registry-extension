# Use a temporary alpine image to generate the manifest
FROM alpine AS manifest
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

RUN mkdir -p /rootfs/usr/local/lib/containers/registry/etc/registry \
             /rootfs/usr/local/lib/containers/registry/var/lib/registry \
 && touch /rootfs/usr/local/lib/containers/registry/etc/registry/.keep \
 && touch /rootfs/usr/local/lib/containers/registry/var/lib/registry/.keep

# Grab the official image to cherry-pick the static binary and certificates
FROM distribution/distribution:3 AS dist

# Final stage: minimal image
FROM scratch

# Copy the generated manifest
COPY --from=manifest /manifest.yaml /manifest.yaml

# Copy the extension service definition
COPY registry.yaml /rootfs/usr/local/etc/containers/registry.yaml
# Create mount points in the container rootfs
COPY --from=manifest /rootfs/usr/local/lib/containers/registry /rootfs/usr/local/lib/containers/registry

# Copy only the statically linked Go binary and CA certificates into the Talos service rootfs
COPY --from=dist /bin/registry /rootfs/usr/local/lib/containers/registry/bin/registry
COPY --from=dist /etc/ssl/certs/ca-certificates.crt /rootfs/usr/local/lib/containers/registry/etc/ssl/certs/ca-certificates.crt
