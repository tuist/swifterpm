#!/usr/bin/env bash
#MISE description="Run end-to-end resolver tests against real-world Package.swift fixtures"
set -euo pipefail

cargo build --locked --release
SWIFTERPM_BIN="${PWD}/target/release/swifterpm" shellspec --shell bash e2e
