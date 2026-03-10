# Talos Registry Extension

This repository contains a Talos system extension that runs a Docker
Distribution container registry as a system service. This ensures a
highly-resilient container registry is available before the Kubernetes cluster
is fully operational.

## How it Works

This project is implemented as a Talos [System
Extension](https://docs.siderolabs.com/talos/overview/what-is-talos). It runs
the standard `distribution/distribution` container image as a service managed by
`machined`.

The extension ensures the registry is started early in the node boot process,
making it independent of the Kubernetes control plane. This allows `kubelet` and
other core Kubernetes components to pull necessary images without relying on a
running in-cluster scheduler or networking.

The configuration for the registry (e.g., storage backend) will be managed via
the Talos machine configuration.

## Usage

### Building the Extension

Use the provided `Makefile` to build the extension image.

```sh
# Build the extension image
make build

# Push to your container registry
make push
```

### Talos Configuration

#### 1. Add the Extension

System extensions should be included at image creation time using the Talos
`imager` tool. Use the `--system-extension-image` flag to include this
extension.

_Note: Replace `${TALOS_VERSION}` and `${EXTENSION_VERSION}` with the correct versions._

```sh
docker run -t --rm -v .:/work --privileged ghcr.io/siderolabs/imager:v${TALOS_VERSION} \
  installer \
  --system-extension-image ghcr.io/containdk/talos-registry-extension:${EXTENSION_VERSION}
```



This will produce a `installer-amd64.tar` file containing the container image.
It can be loaded into docker using:

```sh
docker load -i installer-amd64.tar
```

Once loaded, re-tag the image to match your registry and push it:

```sh
docker tag ghcr.io/siderolabs/installer-base:v${TALOS_VERSION} your-registry/talos-installer-image:v${TALOS_VERSION}
docker push your-registry/talos-installer-image:v${TALOS_VERSION}
```

Remember to match the talos versions.

#### 2. Configure the Service

Once the node is running with the extension, the registry service will start, but it requires a configuration file. This is provided via an `ExtensionServiceConfig` document in your Talos machine configuration.

**Example: Configure the registry via ExtensionServiceConfig**

You must provide the `config.yml` via the `ExtensionServiceConfig` kind. Add the following YAML document to your machine configuration (or apply it as a patch):

```yaml
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
```
