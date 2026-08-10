# talos-nftables-extension

Packages the **nftables** Talos system extension - a daemon (`../talos-extensions/nftables`) that
applies a raw nftables ruleset from an `ExtensionServiceConfig`, with `{{ placeholder }}`
substitution for values only knowable on the running node (currently: which interface carries the
default route, per address family), then stays resident watching (via `nft monitor`) for something
else on the node wiping its tables - confirmed real on a real node (something's first
iptables-nft-mode bootstrap around kubelet/kube-proxy startup can catch unrelated tables in a
one-time boot race), not a hypothetical. No kernel module involved - pure userspace, fully
independent of `../talos-kernel`.

Unlike `../talos-awg-extension`/`../talos-router-extension`, this repo builds **two** things, not
one: its own statically-linked `nft` binary (`patches/pkgs/nftables-pkg/`, built via a
`siderolabs/pkgs` checkout, since `siderolabs/pkgs` already ships an `nftables` package but
dynamically linked - unusable in a `variant: scratch` extension with nothing else staged into it),
and the actual extension image (`patches/extensions/nftables/`, packages that `nft` binary plus the
cross-compiled `nftables` daemon). Both stages live in this one repo - there's no shared one-time
signing key forcing them into separate repos or one buildkit session the way `../talos-kernel`'s
kernel+module build needs.

Builds with **Docker** (`docker buildx`), on any machine, for any target architecture.

## This is one of five repos

```
talos-kernel                               -> signed kernel + amneziawg-pkg
talos-awg-extension                        -> amneziawg system extension (pulls amneziawg-pkg)
talos-router-extension                     -> router system extension (no kernel dependency)
talos-nftables-extension     (this repo)   -> nftables system extension (no kernel dependency)
talos-installer                            -> assembles kernel + N extensions into an installer
```

Each repo builds and publishes independently. Like `talos-router-extension`, this repo doesn't need
`talos-kernel` built first - `preflight` has no dependency-image check.

## Why a statically-linked `nft`, built from source

`siderolabs/pkgs` already has `nftables`/`libmnl`/`libnftnl`/`libjansson` packages (see
`../talos-kernel/build/pkgs/{nftables,libmnl,libnftnl,libjansson}/pkg.yaml` after `make
checkout-pkgs`) - but their `nft` is dynamically linked against the other three's `.so` files. Every
other extension in this pipeline (`amneziawg`, `router`) ships `variant: scratch` with nothing else
staged in - no shared libraries alongside the one binary that needs them - the same reason
`../talos-router-extension` builds `bird` with `-static` rather than using `network/bird2`'s own
dynamically-linked package. `nftables-pkg` here does the same for `nft`: `libmnl` -> `libnftnl` ->
`nftables`, in that dependency order, all built `--disable-shared --enable-static`, `nft` itself
linked with libtool's `-all-static` (plain `-static` in `LDFLAGS` is silently swallowed by libtool -
it means "prefer static libtool libraries" to libtool, not "actually link everything statically";
`-all-static` is libtool's own spelling for that - confirmed the hard way, see
`patches/pkgs/nftables-pkg/pkg.yaml`'s own comments for the two failed attempts before this one).

`--without-cli` drops `nft`'s own interactive/readline-dependent mode (the same role
`--disable-client` plays for BIRD in `../talos-router-extension` - the batch mode this daemon
actually uses, `nft -f -`, doesn't need it). `--with-json=no` drops the `libjansson` dependency
entirely, since nothing here parses or emits JSON. `--with-mini-gmp=yes` avoids an external `libgmp`
dependency (nftables bundles a minimal GMP implementation for exactly this).

**`NFTABLES_VERSION` is deliberately not the latest release** - see `versions.env`'s own comment:
nftables >= 1.1.3 changed on-wire "userdata" format for commented sets/maps in a way that segfaults
kube-proxy 1.36's own (older, bundled) `nft` during a full resync
(kubernetes/kubernetes#136786, fixed only for Kubernetes 1.37's kube-proxy). Pinned to 1.1.1, the
newest release confirmed to predate that change.

## Layout

```
versions.env                      Talos version, pkgs/extensions commits, libmnl/libnftnl/nftables
                                   versions+hashes, image namespace
patches/pkgs/nftables-pkg/        overlaid onto a siderolabs/pkgs checkout - builds a fully static nft
patches/extensions/nftables/      overlaid onto a siderolabs/extensions checkout - packages nft +
                                   the nftables daemon into the final extension
build/                            (gitignored) both checkouts
```

`build/` is disposable: `make distclean && make extension TARGET_ARCH=<arch>` reproduces it from
`versions.env` and `patches/` alone.

The `nftables` daemon binary itself lives in the sibling repo `../talos-extensions` and is
cross-compiled by `make agents`, then handed to the `siderolabs/extensions` checkout for packaging
alongside the vendored `nft` (part of `make extension`).

## Cross-architecture

```sh
make extension TARGET_ARCH=amd64
make extension TARGET_ARCH=arm64
```

## Usage

```sh
make print-config      # resolved pins, arch, image names
make preflight          # docker/buildx/git/curl/cargo/cargo-zigbuild present
make nftables-pkg          # build the static nft binary, push (this arch)
make agents                   # cross-compile nftables from ../talos-extensions
make extension                   # nftables-pkg -> agents -> package (this arch)
make all                            # preflight -> extension
```

`make extension` pushes straight to `docker.io/ffaxl/talos` and prints the tag -
`../talos-installer` needs that ref to bundle it into an installer.

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
after `../talos-installer` bundles this extension and a node runs `talosctl upgrade` - see that
repo's README, and `../talos-extensions/README.md`'s `nftables` section for the daemon's own config
shape and an example `ruleset:`.

## Bumping

**nftables/libmnl/libnftnl:** set `NFTABLES_VERSION`/`LIBMNL_VERSION`/`LIBNFTNL_VERSION`, run `make
hashes`, paste the values back, `make extension TARGET_ARCH=<arch>` - re-check the kube-proxy
compatibility note above before moving `NFTABLES_VERSION` past 1.1.1.

**siderolabs/pkgs, siderolabs/extensions:** bump `UPSTREAM_PKGS_REF`/`UPSTREAM_EXTENSIONS_REF`
freely; they only need to resolve.

**nftables daemon:** any commit in `../talos-extensions` - `make extension` always picks up
whatever's currently checked out there and tags accordingly (see `AGENTS_SHA` in the `Makefile`),
no version bump needed here.
