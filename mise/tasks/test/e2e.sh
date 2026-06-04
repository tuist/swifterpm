#!/usr/bin/env bash
#MISE description="Run end-to-end resolver tests against real-world Package.swift fixtures"
set -euo pipefail

bazel build //:swifterpm
shellspec_args=(--shell bash)
if [[ -n "${SHELLSPEC_JOBS:-}" ]]; then
  shellspec_args+=(--jobs "${SHELLSPEC_JOBS}")
fi

SWIFTERPM_BIN="${PWD}/bazel-bin/swifterpm" shellspec "${shellspec_args[@]}" e2e
