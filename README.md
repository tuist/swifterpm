# swifterpm ⚡

`swifterpm` is a faster Swift package restoration tool built for workflows where dependency resolution happens often, across many clean worktrees, and under heavy concurrency.

## Motivation 🤖

Concurrent package installation is becoming the default in a world of coding agents. A single developer may now have several agents resolving dependencies in parallel, often across different worktrees of the same project. In that world, slow resolution and duplicated package checkouts become very expensive.

Other package managers have already iterated on this problem. Tools like pnpm and aube show that a global cache plus cheap project-local links can make installs both faster and much more disk efficient. Tuist users reported SwiftPM resolution and checkout restoration as a bottleneck, so we felt compelled to solve it for them.

Tuist generated projects gave us a clean contract to replace: package resolution is decoupled from project integration, so `tuist install` can use a faster resolver/restorer before Tuist generates or updates the Xcode project.

> [!IMPORTANT]
> `swifterpm` cannot transparently speed up standard Xcode projects. Xcode integrates SwiftPM internally, and that integration does not expose a supported hook where we can replace the resolver or checkout restorer. For now, this improvement is aimed at Tuist workflows and other flows that can call `swifterpm` before project integration.

## How it works

- **Swift + Bazel implementation**: The CLI is written in Swift, uses structured concurrency for parallel restoration and async HTTP downloads, and is built with Bazel through `rules_swift` plus the `rules_apple` macOS command-line application wrapper.
- **Lockfile fast path**: When `Package.resolved` is available, `swifterpm` can use `--force-resolved-versions` to skip dependency solving and restore exactly the pinned revisions.
- **GitHub archives first**: For GitHub dependencies, it downloads source tarballs for pinned revisions instead of cloning full repositories. A shallow Git fetch is kept as a fallback.
- **Swift registry archives**: Registry packages declared with `.package(id:)` are resolved through SwiftPM-compatible registry configuration, downloaded as checksum-verified ZIP archives, and restored under `.build/registry/downloads`.
- **XDG global source cache**: Archives and extracted source trees are stored once under `$XDG_CACHE_HOME/swifterpm`, or `~/.cache/swifterpm` when `XDG_CACHE_HOME` is unset, keyed by package identity, version, and revision.
- **Project-local checkout shells**: `.build/checkouts` entries stay as real directories whose contents link back to the global cache, so Xcode and Tuist-relative paths keep resolving inside the worktree.
- **Concurrent-safe writes**: Package restoration runs in parallel, while cache writes use file locks, temporary files, and atomic moves so multiple installs can share the same cache safely.
- **Tuist package-info cache**: `swifterpm` can also persist SwiftPM manifest JSON under `.build/swifterpm/package-info`, allowing Tuist to avoid re-running parts of manifest loading later.

## Install and run

Install the latest release with mise:

```sh
mise use -g github:tuist/swifterpm@latest
```

Resolve and restore a package:

```sh
swifterpm --package-path . resolve
```

Use the fastest path when `Package.resolved` already exists:

```sh
swifterpm --package-path . --force-resolved-versions resolve
```

Or run without changing your mise config:

```sh
mise x github:tuist/swifterpm@latest -- swifterpm --package-path . --force-resolved-versions resolve
```

Useful SwiftPM-shaped flags are supported, including `--package-path`, `--cache-path`, `--scratch-path`, `--build-path`, `--config-path`, `--default-registry-url`, `--skip-update`, `--force-resolved-versions`, `--disable-automatic-resolution`, and `--only-use-versions-from-resolved-file`.

## Bazel Swift package resolver

`swifterpm` also ships a Bzlmod extension with the same resolver helper shape as `rules_swift_package_manager`:

```starlark
bazel_dep(name = "swifterpm", version = "0.1.0")

swift_deps = use_extension("@swifterpm//:extensions.bzl", "swift_deps")
swift_deps.from_package(
    resolved = "//:Package.resolved",
    swift = "//:Package.swift",
)
use_repo(swift_deps, "swift_package")
```

Then run:

```sh
bazel run @swift_package//:resolve
bazel run @swift_package//:update
```

The generated `@swift_package` repository downloads the matching `swifterpm-${version}-${target}.tar.gz` binary from GitHub releases and uses it to update `Package.resolved`. For local rule development, override the tool with:

```starlark
swift_deps.configure_swifterpm(
    local_binary = "/absolute/path/to/swifterpm",
)
```

This currently covers the resolver helper API. It does not yet synthesize `swiftpkg_<identity>` Bazel build repositories for package targets.

## Build from source

Build the command-line binary:

```sh
mise exec -- bazel build //:swifterpm
```

Build the Apple rules wrapper:

```sh
mise exec -- bazel build //:swifterpm_macos
```

## Benchmarks 📊

The benchmark script is [mise/tasks/benchmark/resolution.sh](mise/tasks/benchmark/resolution.sh). It clones each repository into a temporary directory, deletes it on completion, and compares SwiftPM against `swifterpm` for cold resolution and worktree-warm resolution.

Run it with:

```sh
mise run benchmark:resolution -- --runs 3
```

Latest single-run sample, generated on macOS 26.4.1 with Apple Swift 6.3.2:

| Codebase | Scenario | SwiftPM | swifterpm | Time reduction | Speedup |
|:---|:---|---:|---:|---:|---:|
| Pocket Casts iOS `Modules/Package.swift` | Cold | 225.498 s | 9.392 s | 95.83% | 24.01x |
| Pocket Casts iOS `Modules/Package.swift` | Worktree-warm | 54.705 s | 0.014 s | 99.97% | 3989.37x |
| Firefox iOS root `Package.swift` | Cold | 37.414 s | 1.203 s | 96.78% | 31.10x |
| Firefox iOS root `Package.swift` | Worktree-warm | 4.439 s | 0.008 s | 99.82% | 522.78x |

Cold resolution removes package-local scratch directories and `swifterpm`'s cache before each run. Worktree-warm resolution removes package-local scratch directories before each run while keeping already-primed global caches, which models switching to another clean worktree.
