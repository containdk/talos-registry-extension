# Use a temporary alpine image to generate the manifest
FROM alpine as manifest
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

# Final stage: minimal image
FROM scratch

# Copy the generated manifest
COPY --from=manifest /manifest.yaml /manifest.yaml

# Copy the extension service definition
COPY registry.yaml /rootfs/usr/local/etc/containers/registry.yaml
# Copy the default registry config
COPY config.yml /rootfs/usr/local/etc/registry/config.yml
