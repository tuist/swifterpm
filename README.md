# swifterpm

`swifterpm` is a Rust prototype for faster Swift package source restoration.

It is not a drop-in SwiftPM replacement yet. The current implementation focuses on the two expensive source-control operations observed in SwiftPM:

- resolution metadata for direct source-control dependencies is fetched through the GitHub API, with `git ls-remote` as a fallback
- restored package sources live once in a global cache, then `.build/checkouts` entries are symlinked to that cache
- semantic version solving is being built around `pubgrub`, with a SwiftPM-specific provider responsible for fetching package versions and manifests

## Commands

```sh
cargo build
target/debug/swifterpm --package-path . resolve
target/debug/swifterpm --package-path . --scratch-path /tmp/package-build resolve
target/debug/swifterpm --package-path . --build-path /tmp/package-build update
target/debug/swifterpm restore --package-dir .
```

`resolve` and `update` accept the SwiftPM-shaped flags that matter for `tuist install`,
including `--package-path`, `--cache-path`, `--scratch-path`, `--build-path`,
`--skip-update`, `--force-resolved-versions`,
`--disable-automatic-resolution`, `--only-use-versions-from-resolved-file`,
and Tuist's current `--replace-scm-with-registry` passthrough. Registry flags are
accepted for command compatibility, but registry resolution is still a separate
piece of work.

By default, `resolve` and `update` write `Package.resolved` and restore checkouts.
Use `--print-only` for the old inspect-only behavior.

The default cache root is:

```text
~/Library/Caches/swifterpm
```

## Tuist fixture

This repository includes a copy of Tuist's `Package.swift` plus its Swift registry configuration. The manifest has:

- 1 direct source-control dependency
- 45 registry dependencies
- 2 local file-system dependencies

The two local dependency directories are expected as ignored local symlinks back to `../tuist`:

```sh
mkdir -p server/native xcode_processor/native
ln -s ../../../tuist/server/native/xcactivitylog_nif server/native/xcactivitylog_nif
ln -s ../../../tuist/xcode_processor/native/xcresult_nif xcode_processor/native/xcresult_nif
```

`swifterpm --package-path . resolve` resolves and restores the direct source-control dependency from this manifest. `swifterpm restore` also handles mixed `Package.resolved` files by restoring source-control pins and skipping registry pins.

## Current boundaries

Registry package resolution is detected but not reimplemented yet. Tuist uses a registry at `https://registry.tuist.dev/api/registry/swift`, so full Tuist graph parity requires implementing the Swift Package Registry protocol, authentication, registry archive caching, and transitive manifest resolution.

The resolver core should be split in two layers:

- PubGrub solver: pure version selection over package identities, semantic versions, and ranges.
- SwiftPM provider: lists available versions from GitHub tags/releases or Swift registries, fetches the manifest for a selected `(package, version)`, converts SwiftPM requirements into PubGrub ranges, and reports unavailable packages or versions.

Revision and branch dependencies sit outside PubGrub because they are not semantic version sets. They should remain direct pins or use the Git fallback path.

For source-control packages, the cache stores extracted source archives rather than full Git mirrors. That is intentionally smaller and faster, but it means workflows that require a mutable Git checkout need a fallback mode.

## Cache Model

The cache is split like modern package managers such as aube and pnpm:

- `archives/`: compressed GitHub tarballs keyed by URL and revision
- `sources/`: immutable extracted source trees keyed by package identity, version, and revision
- `metadata/remotes/`: available version metadata keyed by repository URL, with a short freshness window
- project `.build/checkouts`: symlinks back to `sources/`

Aube also has a global virtual store for already-materialized package directory trees. `swifterpm`'s equivalent is simpler because Swift package checkouts do not need Node's nested module graph: the extracted source tree is the materialized unit, and project checkouts are symlinks to it.

Restore materializes source-control pins in parallel. That keeps cold restores from waiting on one archive download or extraction at a time and makes warm restores mostly filesystem link work.

## Benchmarks

GitHubized Tuist fixture:

- 83 pins
- 83 `remoteSourceControl` pins
- 0 registry pins

Cold clean `.build`, one run:

```text
swift package resolve                  25.476 s
swifterpm restore, empty cache          7.777 s
```

Warm cache, repeated clean `.build` restore:

```text
swifterpm restore                      28.8 ms +/- 0.9 ms
```

Warm existing SwiftPM `.build` versus existing swifterpm checkout symlinks:

```text
swift package resolve                   1.048 s +/- 0.006 s
swifterpm restore                      29.6 ms +/- 2.1 ms
```

Disk after cold restore:

```text
SwiftPM .build                         1.9 GB
  repositories                          848 MB
  checkouts                             901 MB

swifterpm project .build                 44 KB
swifterpm global cache                  659 MB
  sources                               525 MB
  archives                              134 MB
```
