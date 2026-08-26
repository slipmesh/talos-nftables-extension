# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### CI/CD ⚙️

- Pin amd64 matrix runner to ubuntu-24.04, not the floating ubuntu-latest alias

### Documentation 📚

- Address the reader who cloned one repository, not five
- State the facts, drop how they were found
- Scope the QEMU note to local builds

### Miscellaneous 🧹

- Add the standard markdownlint config, fix what it found

## [0.1.1+nftables1.1.5] - 2026-08-19

### Added ✨

- Bump nftables to 1.1.6, retag for Talos 1.13.9

### CI/CD ⚙️

- Build arm64 on a native runner instead of QEMU-emulated amd64

### Fixed 🐛

- Nftables 1.1.6 fails to build in the musl cross toolchain, use 1.1.5

## [0.1.0+nftables1.1.1] - 2026-08-17

### Added ✨

- Initial commit: nftables extension packaging (static nft + watchdog daemon)

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and release CI
- Tag releases like the bird repo: git release tag = published image tag
