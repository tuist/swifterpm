# Resolution benchmark

Generated with `mise run benchmark:resolution -- --runs 1`.

Cold resolution removes package-local scratch directories and swifterpm's global cache before each measured run.
Worktree-warm resolution removes package-local scratch directories before each measured run, but keeps already-primed global caches to model switching to another clean worktree.

## Pocket Casts iOS Modules: cold

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `swift package resolve (cold)` | 157.436 | 157.436 | 157.436 | 2.92 |
| `swifterpm resolve (cold)` | 53.927 | 53.927 | 53.927 | 1.00 |

swifterpm reduced mean resolution time by 65.75% (2.92x speedup).

## Pocket Casts iOS Modules: worktree-warm

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `swift package resolve (worktree-warm)` | 76.226 | 76.226 | 76.226 | 244.77 |
| `swifterpm resolve (worktree-warm)` | 0.311 | 0.311 | 0.311 | 1.00 |

swifterpm reduced mean resolution time by 99.59% (244.77x speedup).

## Firefox iOS: cold

| Command | Mean [s] | Min [s] | Max [s] | Relative |
|:---|---:|---:|---:|---:|
| `swift package resolve (cold)` | 15.785 | 15.785 | 15.785 | 4.23 |
| `swifterpm resolve (cold)` | 3.733 | 3.733 | 3.733 | 1.00 |

swifterpm reduced mean resolution time by 76.35% (4.23x speedup).

