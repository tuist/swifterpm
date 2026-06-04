#!/usr/bin/env bash
#MISE description="Run end-to-end resolver tests against real-world Package.swift fixtures"
set -euo pipefail

bazel build //:swifterpm
SWIFTERPM_BIN="${PWD}/bazel-bin/swifterpm" shellspec --shell bash e2e
