#!/usr/bin/env bash
#MISE description="Run end-to-end ShellSpec resolver tests"
set -euo pipefail

cargo build --locked --release
SWIFTERPM_BIN="${PWD}/target/release/swifterpm" shellspec --shell bash spec
