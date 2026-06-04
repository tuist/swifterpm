#!/usr/bin/env bash
#MISE description="Run Swift unit tests"
set -euo pipefail

bazel test //:swifterpm_tests
