# Builds a statically-linked `nft` (libmnl -> libnftnl -> nftables from source, see
# patches/pkgs/nftables-pkg/pkg.yaml) and packages it, together with the `nftables`
# extension-service daemon (../talos-extensions), into a Talos system extension image -
# both stages live in this one repo (unlike talos-awg-extension/talos-kernel's split):
# there's no shared one-time signing key forcing the pkgs and extensions stages into one
# buildkit session here, so there's no reason to force them into two repos either.
#
# Needs Docker + `docker buildx` (siderolabs' real `bldr` toolchain, a custom BuildKit
# frontend podman/buildah can't run).
#
# One of five repos in the split pipeline (talos-kernel, talos-awg-extension,
# talos-router-extension, talos-nftables-extension, talos-installer) - see each repo's own
# README for how they're wired together by tag. This one is entirely self-contained: no
# dependency on ../talos-kernel (pure userspace, no kernel module).
#
# build/ is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces
# it from versions.env and patches/ alone.

include versions.env

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# No silent single-arch default: nodes are amd64 and arm64 both, so a bare `make all`
# picking one quietly is how you forget to build the other. Pass TARGET_ARCH explicitly.
_GOALS := $(or $(MAKECMDGOALS),$(.DEFAULT_GOAL))
ifeq ($(TARGET_ARCH),)
  ifneq ($(filter-out distclean help hashes checkout-pkgs checkout-extensions,$(_GOALS)),)
    $(error TARGET_ARCH not set - pass TARGET_ARCH=amd64 or TARGET_ARCH=arm64)
  endif
endif
ifeq ($(RELEASE_TAG),)
  ifneq ($(filter-out distclean help hashes checkout-pkgs checkout-extensions,$(_GOALS)),)
    $(error RELEASE_TAG not set - pass RELEASE_TAG=v0.1.0+nftables$(NFTABLES_VERSION), the git tag this build is released under)
  endif
endif

BUILD_DIR      := build
PKGS_DIR       := $(BUILD_DIR)/pkgs
EXTENSIONS_DIR := $(BUILD_DIR)/extensions

# The `nftables` extension-service daemon lives in a sibling repo, not here - this repo
# only cross-compiles it and hands the binary to the siderolabs/extensions checkout for
# packaging. See that repo's README/AGENTS.md for what it does.
AGENTS_DIR              := ../talos-extensions
AGENT_RUST_TARGET_amd64 := x86_64-unknown-linux-musl
AGENT_RUST_TARGET_arm64 := aarch64-unknown-linux-musl
AGENT_RUST_TARGET       := $(AGENT_RUST_TARGET_$(TARGET_ARCH))
AGENTS_SHA              := $(shell git -C $(AGENTS_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown)

# Same namespace ../talos-kernel publishes kernel/amneziawg-pkg under (DOCKER_NS there) -
# the pkgs-stage artifact this repo builds (nftables-pkg) follows that repo's naming
# convention (<namespace>/<pkg-name>:<tag>), not this repo's own IMAGE (which is for the
# *extension* image, following ../talos-router-extension's single-IMAGE-many-tag-prefixes
# convention instead) - the two stages predate a shared convention and siderolabs/
# extensions' own pkg.yaml templates (PKGS_PREFIX + "/nftables-pkg:" + PKGS) expect the
# namespace shape specifically, not a flat IMAGE:tag.
PKGS_NS  := ghcr.io/slipmesh
PKGS_TAG := $(TALOS_VERSION)-nft$(NFTABLES_VERSION)

NFTABLES_PKG_IMAGE := $(PKGS_NS)/nftables-pkg:$(PKGS_TAG)-$(TARGET_ARCH)

##@ General

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Show the resolved pins, arch and image names.
	@echo "talos            : $(TALOS_VERSION)"
	@echo "pkgs ref         : $(UPSTREAM_PKGS_REF)"
	@echo "extensions ref   : $(UPSTREAM_EXTENSIONS_REF)"
	@echo "libmnl           : $(LIBMNL_VERSION)"
	@echo "libnftnl         : $(LIBNFTNL_VERSION)"
	@echo "nftables         : $(NFTABLES_VERSION)"
	@echo "host arch        : $$(uname -m)"
	@echo "target arch      : $(TARGET_ARCH)"
	@echo "release tag      : $(RELEASE_TAG)"
	@echo "nftables-pkg     : $(NFTABLES_PKG_IMAGE)"
	@echo "extension image  : $(EXT_IMAGE)"

.PHONY: preflight
preflight: ## Check this machine can run the build.
	@fail=0; \
	for t in docker git curl; do command -v $$t >/dev/null || { echo "MISSING: $$t"; fail=1; }; done; \
	docker buildx version >/dev/null 2>&1 || { echo "MISSING: docker buildx"; fail=1; }; \
	docker version >/dev/null 2>&1 || { echo "docker daemon not reachable (permission denied or not running)"; fail=1; }; \
	command -v cargo >/dev/null || { echo "MISSING: cargo"; fail=1; }; \
	command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild (cargo install cargo-zigbuild --locked)"; fail=1; }; \
	[ -d $(AGENTS_DIR) ] || { echo "MISSING: sibling checkout $(AGENTS_DIR)"; fail=1; }; \
	echo "host $$(uname -m)"; \
	[ $$fail -eq 0 ] && echo "preflight OK" || exit 1

##@ Build - pkgs stage (our own statically-linked nft)

$(BUILD_DIR):
	@mkdir -p $@

.PHONY: checkout-pkgs
checkout-pkgs: | $(BUILD_DIR) ## Fetch siderolabs/pkgs at the pinned commit, overlay patches/pkgs/.
	@if [ ! -d "$(PKGS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/pkgs"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/pkgs.git $(PKGS_DIR); \
	fi
	@git -C $(PKGS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_PKGS_REF) 2>/dev/null || git -C $(PKGS_DIR) fetch --quiet origin
	@git -C $(PKGS_DIR) checkout --quiet --force --detach $(UPSTREAM_PKGS_REF)
	@rm -rf $(PKGS_DIR)/nftables-pkg
	@cp -r patches/pkgs/nftables-pkg $(PKGS_DIR)/nftables-pkg

NFTABLES_PKG_ARGS := \
  --build-arg=LIBMNL_VERSION=$(LIBMNL_VERSION) --build-arg=LIBMNL_SHA256=$(LIBMNL_SHA256) --build-arg=LIBMNL_SHA512=$(LIBMNL_SHA512) \
  --build-arg=LIBNFTNL_VERSION=$(LIBNFTNL_VERSION) --build-arg=LIBNFTNL_SHA256=$(LIBNFTNL_SHA256) --build-arg=LIBNFTNL_SHA512=$(LIBNFTNL_SHA512) \
  --build-arg=NFTABLES_VERSION=$(NFTABLES_VERSION) --build-arg=NFTABLES_SHA256=$(NFTABLES_SHA256) --build-arg=NFTABLES_SHA512=$(NFTABLES_SHA512)

.PHONY: nftables-pkg
nftables-pkg: checkout-pkgs ## Build our own statically-linked nft (libmnl -> libnftnl -> nftables), push.
	@echo "==> building $(NFTABLES_PKG_IMAGE) ($(TARGET_ARCH))"
	@$(MAKE) -C $(PKGS_DIR) docker-nftables-pkg PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(NFTABLES_PKG_IMAGE) --push=true $(NFTABLES_PKG_ARGS)"

##@ Build - extensions stage (package nft + the nftables daemon)

.PHONY: checkout-extensions
checkout-extensions: | $(BUILD_DIR) ## Fetch siderolabs/extensions at the pinned commit, overlay patches/extensions/.
	@if [ ! -d "$(EXTENSIONS_DIR)/.git" ]; then \
	  echo "==> cloning siderolabs/extensions"; \
	  git clone --filter=blob:none --quiet https://github.com/siderolabs/extensions.git $(EXTENSIONS_DIR); \
	fi
	@git -C $(EXTENSIONS_DIR) fetch --quiet --filter=blob:none origin $(UPSTREAM_EXTENSIONS_REF) 2>/dev/null || git -C $(EXTENSIONS_DIR) fetch --quiet origin
	@git -C $(EXTENSIONS_DIR) checkout --quiet --force --detach $(UPSTREAM_EXTENSIONS_REF)
	@rm -rf $(EXTENSIONS_DIR)/nftables
	@cp -r patches/extensions/nftables $(EXTENSIONS_DIR)/nftables

.PHONY: agents
agents: ## Cross-compile the nftables extension-service daemon (../talos-extensions).
	@test -d $(AGENTS_DIR) || { echo "sibling checkout not found: $(AGENTS_DIR)"; exit 1; }
	@command -v cargo-zigbuild >/dev/null || { echo "MISSING: cargo-zigbuild"; exit 1; }
	@rustup target add $(AGENT_RUST_TARGET) >/dev/null 2>&1 || true
	@echo "==> cross-compiling nftables for $(TARGET_ARCH) ($(AGENT_RUST_TARGET))"
	@(cd $(AGENTS_DIR) && cargo zigbuild --release --target $(AGENT_RUST_TARGET) -p nftables)

# Same field-order requirement as ../talos-awg-extension's/../talos-router-extension's own
# EXT_VERSION: siderolabs' extensions-validator only accepts a handful of exact version
# shapes via regex, and `<hash>-v<talos-semver>[-suffix]` is the one that fits - see either
# of those Makefiles for the exact regex and why AGENTS_SHA has to come first.
EXT_VERSION := $(AGENTS_SHA)-$(TALOS_VERSION)-nft$(NFTABLES_VERSION)

# Registry tag follows ../bird's own convention: the git release tag *is* the image tag
# (`+` swapped for `-`, since OCI tags can't contain `+`) - RELEASE_TAG is required, not
# derived from versions.env pins, so a rebuild after bumping NFTABLES_VERSION or
# ../talos-extensions' commit still needs an explicit new release to publish under (the old
# PKGS_TAG+AGENTS_SHA-keyed scheme's staleness fix is now just "cut a new release"; see
# ../talos-installer/README.md's BUILD_SLUG for the general form of the underlying bug).
# NFTABLES_PKG_IMAGE (the intermediate pkgs-stage image, above) is a purely internal
# artifact no other repo ever names directly, so it keeps its versions.env-derived tag.
RELEASE_TAG_SAFE := $(subst +,-,$(RELEASE_TAG))
EXT_IMAGE := $(IMAGE):$(RELEASE_TAG_SAFE)-$(TARGET_ARCH)

.PHONY: extension
extension: nftables-pkg agents checkout-extensions ## Package nft + the nftables daemon into a Talos system extension image (bldr).
	@cp $(AGENTS_DIR)/target/$(AGENT_RUST_TARGET)/release/nftables $(EXTENSIONS_DIR)/nftables/nftables-bin
	@cp $(AGENTS_DIR)/extension-services/nftables.yaml $(EXTENSIONS_DIR)/nftables/nftables-service.yaml
	@echo "==> building $(EXT_IMAGE) ($(TARGET_ARCH))"
	@$(MAKE) -C $(EXTENSIONS_DIR) docker-nftables PLATFORM=linux/$(TARGET_ARCH) \
	  TARGET_ARGS="--tag=$(EXT_IMAGE) --push=true \
	    --build-arg=PKGS_PREFIX=$(PKGS_NS) --build-arg=PKGS=$(PKGS_TAG)-$(TARGET_ARCH) --build-arg=VERSION=$(EXT_VERSION)"
	@echo
	@echo "published: $(EXT_IMAGE)"
	@echo "talos-installer needs this ref to bundle it into an installer"

.PHONY: all
all: preflight extension ## Everything: nft pkg -> agents -> extension image.

##@ Maintenance

.PHONY: hashes
hashes: ## Recompute LIBMNL_/LIBNFTNL_/NFTABLES_ SHA256/SHA512 for the current *_VERSION values.
	@for spec in "libmnl:https://www.netfilter.org/projects/libmnl/files/libmnl-$(LIBMNL_VERSION).tar.bz2:LIBMNL" \
	             "libnftnl:https://netfilter.org/projects/libnftnl/files/libnftnl-$(LIBNFTNL_VERSION).tar.xz:LIBNFTNL" \
	             "nftables:https://netfilter.org/projects/nftables/files/nftables-$(NFTABLES_VERSION).tar.xz:NFTABLES"; do \
	  name=$${spec%%:*}; rest=$${spec#*:}; url=$${rest%:*}; var=$${rest##*:}; \
	  tmp=$$(mktemp); \
	  curl -sSL --fail "$$url" -o "$$tmp"; \
	  echo "$${var}_SHA256=$$(sha256sum "$$tmp" | cut -d' ' -f1)"; \
	  echo "$${var}_SHA512=$$(sha512sum "$$tmp" | cut -d' ' -f1)"; \
	  rm -f "$$tmp"; \
	done

.PHONY: clean
clean: ## No separate build output to drop - kept for symmetry with the other repos.
	@true

.PHONY: distclean
distclean: ## Drop everything, including the pinned checkouts.
	@rm -rf $(BUILD_DIR)
