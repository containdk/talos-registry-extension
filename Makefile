# Makefile for Talos Registry Extension

REGISTRY ?= ghcr.io/containdk
IMAGE_NAME ?= talos-registry-extension
PLATFORMS ?= linux/amd64,linux/arm64

# Default Talos version to build against. Can be overridden.
TALOS_VERSION ?= v1.14
# Get the latest git tag without the 'v' prefix for the application version.
GIT_TAG := $(shell git describe --tags --abbrev=0 2>/dev/null)
VERSION ?= $(if $(GIT_TAG),$(shell echo $(GIT_TAG) | sed 's/^v//'),0.0.0-dev)
# The full version string used for the manifest and image tag.
FULL_VERSION = $(VERSION)-$(TALOS_VERSION)

IMAGE_URL = $(REGISTRY)/$(IMAGE_NAME)

# Multi-platform builds require the docker-container driver; the "docker"
# driver cannot produce multi-arch manifests. If the currently selected buildx
# builder uses the docker driver (typical for a plain local Docker/Colima
# setup), fall back to a dedicated container builder, created on demand.
# In CI, where setup-buildx-action already selects a container builder, this
# resolves to empty and the selected builder is used as-is.
FALLBACK_BUILDER ?= multiarch
BUILDER = $(shell docker buildx inspect 2>/dev/null | awk -F': *' '/^Driver:/{print $$2}' | grep -qx docker && echo $(FALLBACK_BUILDER))
BUILDER_FLAG = $(if $(BUILDER),--builder $(BUILDER))

.PHONY: all build push clean check-git-clean check-release-tag test-local buildx-builder

all: build

# Build for the local host platform and load into the local Docker daemon
build:
	@echo "Building extension image for local platform: $(IMAGE_URL):$(FULL_VERSION)"
	docker buildx build --load \
		--build-arg VERSION=$(VERSION) \
		--build-arg TALOS_VERSION=$(TALOS_VERSION) \
		-t $(IMAGE_URL):$(FULL_VERSION) \
		-t $(IMAGE_URL):latest \
		.

# Ensure a multi-platform capable builder exists
buildx-builder:
	@builder='$(BUILDER)'; \
	if [ -n "$$builder" ] && ! docker buildx inspect "$$builder" >/dev/null 2>&1; then \
		echo "Creating buildx builder '$$builder' (docker-container driver)..."; \
		docker buildx create --name "$$builder" --driver docker-container --bootstrap >/dev/null; \
	fi

# Build and push the multi-platform manifest for both amd64 and arm64
push: check-git-clean buildx-builder
	@echo "Building and pushing extension image for $(PLATFORMS) as $(IMAGE_URL):$(FULL_VERSION)"
	docker buildx build $(BUILDER_FLAG) --platform $(PLATFORMS) \
		--build-arg VERSION=$(VERSION) \
		--build-arg TALOS_VERSION=$(TALOS_VERSION) \
		-t $(IMAGE_URL):$(FULL_VERSION) \
		-t $(IMAGE_URL):latest \
		--push .

check-git-clean:
	@if ! git diff-index --quiet HEAD --; then \
		echo "Git working directory is dirty. Please commit or stash changes before building."; \
		exit 1; \
	fi

clean:
	@echo "Removing local images..."
	@docker rmi $(IMAGE_URL):$(FULL_VERSION) >/dev/null 2>&1 || true
	@docker rmi $(IMAGE_URL):latest >/dev/null 2>&1 || true
	@echo "Clean complete."

test-local:
	TALOS_VERSION=$(TALOS_VERSION) ./scripts/test-local.sh

destroy-test-local:
	@sudo talosctl cluster destroy --name reg-test
