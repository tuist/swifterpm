#!/usr/bin/env bash
#MISE description="Build and package a release archive for a target triple"
#USAGE flag "--target <target>" help="Rust target triple to compile"
#USAGE flag "--version <version>" help="Version number to embed in the asset name"
set -euo pipefail

target=""
version=""
while (($# > 0)); do
  case "$1" in
    --target)
      target="${2}"
      shift 2
      ;;
    --version)
      version="${2}"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${target}" || -z "${version}" ]]; then
  echo "--target and --version are required" >&2
  exit 1
fi

mkdir -p dist
cargo build --locked --release --target "${target}"

case "${target}" in
  *-windows-*)
    bin_name="swifterpm.exe"
    ;;
  *)
    bin_name="swifterpm"
    ;;
esac

stage_dir="$(mktemp -d)"
trap 'rm -rf "${stage_dir}"' EXIT
cp "target/${target}/release/${bin_name}" "${stage_dir}/${bin_name}"

asset="swifterpm-${version}-${target}.tar.gz"
tar -C "${stage_dir}" -czf "dist/${asset}" "${bin_name}"
