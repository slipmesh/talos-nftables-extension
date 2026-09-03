# talos-nftables-extension

Packages the **nftables** Talos system extension - a daemon (`talos-extensions/nftables`) that
applies a raw nftables ruleset from an `ExtensionServiceConfig`, with `{{ placeholder }}`
substitution for values only knowable on the running node (currently: which interface carries the
default route, per address family), then stays resident watching (via `nft monitor`) for something
else on the node wiping its tables - confirmed real on a real node (something's first
iptables-nft-mode bootstrap around kubelet/kube-proxy startup can catch unrelated tables in a
one-time boot race), not a hypothetical. No kernel module involved - pure userspace, fully
independent of `talos-kernel`.

Unlike `talos-awg-extension`/`talos-router-extension`, this repo builds **two** things, not
one: its own statically-linked `nft` binary (`patches/pkgs/nftables-pkg/`, built via a
`siderolabs/pkgs` checkout, since `siderolabs/pkgs` already ships an `nftables` package but
dynamically linked - unusable in a `variant: scratch` extension with nothing else staged into it),
and the actual extension image (`patches/extensions/nftables/`, packages that `nft` binary plus the
cross-compiled `nftables` daemon). Both stages live in this one repo - there's no shared one-time
signing key forcing them into separate repos or one buildkit session the way `talos-kernel`'s
kernel+module build needs.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.

## This is one of five repos

- [talos-kernel](https://github.com/slipmesh/talos-kernel) —
  signed kernel + `amneziawg-pkg`
- [talos-awg-extension](https://github.com/slipmesh/talos-awg-extension) —
  amneziawg system extension (pulls `amneziawg-pkg`)
- [talos-router-extension](https://github.com/slipmesh/talos-router-extension) —
  router system extension (no kernel dependency)
- [talos-nftables-extension](https://github.com/slipmesh/talos-nftables-extension) —
  nftables system extension (no kernel dependency) — **this repo**
- [talos-installer](https://github.com/slipmesh/talos-installer) —
  assembles a kernel + N extensions into an installer

Each repo builds and publishes independently. Like `talos-router-extension`, this repo doesn't need
`talos-kernel` built first - `preflight` has no dependency-image check.

### One checkout it does need

`make daemons` cross-compiles the daemon out of
[talos-extensions](https://github.com/slipmesh/talos-extensions), so that repository has to exist
on disk - it's the one thing here that isn't consumed as a published image. The default is a
sibling checkout, `DAEMONS_DIR := ../talos-extensions`; clone the two side by side, or point it
anywhere:

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=... DAEMONS_DIR=/path/to/talos-extensions
```

`preflight` fails loudly if the directory isn't there.

## Why a statically-linked `nft`, built from source

`siderolabs/pkgs` already has `nftables`/`libmnl`/`libnftnl`/`libjansson` packages (see
`talos-kernel/build/pkgs/{nftables,libmnl,libnftnl,libjansson}/pkg.yaml` after `make
checkout-pkgs`) - but their `nft` is dynamically linked against the other three's `.so` files. Every
other extension in this pipeline (`amneziawg`, `router`) ships `variant: scratch` with nothing else
staged in - no shared libraries alongside the one binary that needs them - the same reason
`talos-router-extension` builds `bird` with `-static` rather than using `network/bird2`'s own
dynamically-linked package. `nftables-pkg` here does the same for `nft`: `libmnl` -> `libnftnl` ->
`nftables`, in that dependency order, all built `--disable-shared --enable-static`, `nft` itself
linked with libtool's `-all-static` (plain `-static` in `LDFLAGS` is silently swallowed by libtool -
it means "prefer static libtool libraries" to libtool, not "actually link everything statically";
`-all-static` is libtool's own spelling for that).

`--without-cli` drops `nft`'s own interactive/readline-dependent mode (the same role
`--disable-client` plays for BIRD in `talos-router-extension` - the batch mode this daemon
actually uses, `nft -f -`, doesn't need it). `--with-json=no` drops the `libjansson` dependency
entirely, since nothing here parses or emits JSON. `--with-mini-gmp=yes` avoids an external `libgmp`
dependency (nftables bundles a minimal GMP implementation for exactly this).

**`NFTABLES_VERSION` was held below 1.1.3 for a while** - see `versions.env`'s own comment: nftables
>= 1.1.3 changed the on-wire "userdata" format for commented sets/maps in a way that segfaulted
kube-proxy's own (older, bundled) `nft` during a full resync (kubernetes/kubernetes#136786). Fixed
in kube-proxy as of Kubernetes 1.36.3 (kubernetes/kubernetes#140405) - now pinned to the latest
stable release again.

## Layout

```text
versions.env                      Talos version, pkgs/extensions commits, libmnl/libnftnl/nftables
                                   versions+hashes, image namespace
patches/pkgs/nftables-pkg/        overlaid onto a siderolabs/pkgs checkout - builds a fully static nft
patches/extensions/nftables/      overlaid onto a siderolabs/extensions checkout - packages nft +
                                   the nftables daemon into the final extension
build/                            (gitignored) both checkouts
```

`build/` is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces it from
`versions.env` and `patches/` alone.

The `nftables` daemon binary itself lives in the sibling repo `talos-extensions` and is
cross-compiled by `make daemons`, then handed to the `siderolabs/extensions` checkout for packaging
alongside the vendored `nft` (part of `make extension`).

## Cross-architecture

```sh
make extension TARGET_ARCH=amd64 RELEASE_TAG=v0.1.1+nftables1.1.5
make extension TARGET_ARCH=arm64 RELEASE_TAG=v0.1.1+nftables1.1.5
```

## Usage

`extension`/`all` need `TARGET_ARCH=amd64|arm64` and `RELEASE_TAG=<the git tag being
released>` (no defaults). Like `bird`, `RELEASE_TAG` *is* the published extension image
tag (`+` swapped for `-`, since OCI tags can't contain `+`) - see `cliff.toml`'s
`tag_pattern` for the exact shape (`vX.Y.Z[+nftablesA.B.C]`). The intermediate
`nftables-pkg` stage keeps its own `versions.env`-derived tag - nothing outside this repo
ever names it directly.

```sh
make print-config      # resolved pins, arch, image names
make preflight          # docker/buildx/git/curl/cargo/cargo-zigbuild present
make nftables-pkg          # build the static nft binary, push (this arch)
make daemons                   # cross-compile nftables from ../talos-extensions
make extension                   # nftables-pkg -> agents -> package (this arch)
make all                            # preflight -> extension
```

`make extension` pushes straight to `ghcr.io/slipmesh/talos-nftables-extension` and prints the tag -
`talos-installer` needs that ref to bundle it into an installer.

## Verifying a build

`patches/pkgs/nftables-pkg/pkg.yaml`'s own `test:` step checks the built `nft` has no `PT_INTERP`
program header (i.e. is genuinely static, not just mostly) before it's even packaged.
`patches/extensions/nftables/pkg.yaml`'s own `test:` step runs siderolabs' own
`extensions-validator` against the assembled manifest/rootfs - a build that completes has already
proven the extension is structurally valid.

```sh
docker buildx imagetools inspect <image>   # arch, manifest
```

Full node-level verification (the daemon actually applying rules, MSS clamp/NAT working, tables
surviving the boot-time race with kube-proxy's own bootstrap) happens
after `talos-installer` bundles this extension and a node runs `talosctl upgrade` - see that
repo's README, and `talos-extensions/README.md`'s `nftables` section for the daemon's own config
shape and an example `ruleset:`.

## Bumping

**nftables/libmnl/libnftnl:** set `NFTABLES_VERSION`/`LIBMNL_VERSION`/`LIBNFTNL_VERSION`, run `make
hashes`, paste the values back, `make extension TARGET_ARCH=<arch> RELEASE_TAG=<new release tag>`.
The kube-proxy incompatibility that held `NFTABLES_VERSION` at 1.1.1 (see `versions.env`) is fixed
as of Kubernetes 1.36.3 - re-check the cluster's actual Kubernetes version is >= 1.36.3 (or >=
1.37.0) before moving `NFTABLES_VERSION` past 1.1.1 on a cluster still running an older patch.

**siderolabs/pkgs, siderolabs/extensions:** bump `PKGS`/`UPSTREAM_EXTENSIONS_REF`
freely; they only need to resolve.

**nftables daemon:** the `talos-extensions` release tag named by `DAEMONS_REF` -
`make check-daemons` refuses to build unless the sibling checkout sits at it, and
`DAEMONS_SHA` records the commit into `EXT_VERSION`. To pick up new daemon work, tag
`talos-extensions` and bump `DAEMONS_REF`.
