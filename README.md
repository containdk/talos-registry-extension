# Talos Registry Extension

This repository contains a Talos system extension that runs a Zot
container registry as a system service. This ensures a
highly-resilient container registry is available before the Kubernetes cluster
is fully operational. The most common use case is to have a local registry for
images that are not available in public registries and that should always be
available in every node in the cluster.

## How it Works

This project is implemented as a Talos [System
Extension](https://docs.siderolabs.com/talos/overview/what-is-talos). It runs
the minimal Zot container image (`project-zot/zot-minimal`).

_Note: We use the `zot-minimal` image because we do not need the extra Zot
extensions. If extensions are needed in the future, Zot should be compiled with
only those specific extensions enabled instead of using the full `zot` image.
See the [Zot Security Posture
documentation](https://zotregistry.dev/v2.1.15/articles/security-posture/)._

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

Once the node is running with the extension, the registry service will start,
but it requires a configuration file. This is provided via an
`ExtensionServiceConfig` document in your Talos machine configuration.

**Example: Configure the registry via ExtensionServiceConfig**

You must provide the `config.json` via the `ExtensionServiceConfig` kind. Add
the following YAML document to your machine configuration (or apply it as a
patch):

```yaml
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
```

### Advanced Zot Configuration

Zot supports various advanced configurations directly in the `config.json`.

**Important:** All referenced files in these configurations (such as TLS
certificates, `htpasswd` files, or bearer tokens) MUST also be written to the
container by adding them as additional items in the `configFiles` array of your
`ExtensionServiceConfig` document.

#### Enable TLS

```json
"http": {
  "tls": {
    "cert": "/etc/zot/certs/server.cert",
    "key": "/etc/zot/certs/server.key",
    "cacert": "/etc/zot/certs/ca.crt"
  }
}
```

#### Prevent Brute Force Attacks

```json
"http": {
  "auth": {
    "failDelay": 5
  }
}
```

#### Configure Credentials with htpasswd

Generate the credentials locally:

```sh
htpasswd -bBn <username> <password> >> htpasswd
```

Then provide it via `ExtensionServiceConfig` (under a new `mountPath` like
`/etc/zot/htpasswd`) and configure `http.auth.htpasswd` in your Zot config:

```json
"http": {
  "auth": {
    "htpasswd": {
      "path": "/etc/zot/htpasswd"
    }
  }
}
```

#### Configure Authorization

Zot supports detailed access control policies via the `accessControl` block. For
most use cases, you only need a robot account with write access and anonymous
read access to everything else:

```json
"accessControl": {
  "repositories": {
    "**": {
      "policies": [
        {
          "users": ["robot"],
          "actions": ["create", "read", "update", "delete"]
        }
      ],
      "anonymousPolicy": ["read"],
      "defaultPolicy": ["read"]
    }
  }
}
```
