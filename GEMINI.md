# Talos Registry Extension Project

This project is a Talos system extension for a highly-resilient container registry.

## Business Goal

As a platform engineer, I need a highly resilient container registry that is available before the Kubernetes cluster is fully operational. This is a critical requirement to prevent bootstrap deadlocks where the cluster cannot start because it cannot pull its own required images.

## Technical Overview

This project involves creating a custom Talos extension to run a container registry as a system service directly on the Talos nodes. The implementation will use the standard Docker Distribution registry image (`distribution/distribution`).

The extension will ensure the registry is started by the Talos service manager (`machined`), making it independent of the Kubernetes control plane. This approach guarantees that the registry is available early in the node boot process, allowing the kubelet and other core Kubernetes components to pull necessary images without relying on a running in-cluster scheduler or networking.

The configuration for the registry (e.g., storage backend) will be managed via the Talos machine configuration.

## Acceptance Criteria

*   A new Talos extension is created for the Docker Distribution registry.
*   The extension is configured to run the registry as a system service on management cluster nodes.
*   The registry starts successfully on boot, independent of the Kubernetes cluster state.
*   Kubelet and other components can pull images from this node-local registry.
*   The extension's configuration and build process are documented and automated.

## Reason for Creation

We originally used zot inside the air-gapped cluster, copied images from the talos image cache to the zot registry at bootstrap the pivoted to zot for the rest of the cluster to use as registry. The problem with that approach is, that if zot disappears (crashes, is deleted, etc) the cluster effectively loses its registry and is unable to start workloads - even zot will not be able to start, and this makes getting back to a usable state hard.

## Talos Service Definition

The Talos service definition can be found at: https://raw.githubusercontent.com/siderolabs/talos/refs/heads/main/pkg/machinery/extensions/services/services.go

Note that `containers` in `registry.yaml` do *not* follow the usual container definition format.
