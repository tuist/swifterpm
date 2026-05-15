# End-to-end resolver tests against real-world Package.swift fixtures.
#
# Each scenario pins an upstream repository to a specific commit, downloads the
# manifest file via raw.githubusercontent.com, resolves it with swifterpm, and
# verifies that the resulting Package.resolved is accepted by SwiftPM with
# `--force-resolved-versions`. Every scenario runs inside its own temp tree
# scoped through a RETURN trap so nothing leaks into the host filesystem or
# the user's caches.

# Pinned upstream sources.
POCKET_CASTS_REPO="Automattic/pocket-casts-ios"
POCKET_CASTS_SHA="43552c30d4121ea6bd8d2ea5cb53ee46c76f267e"
POCKET_CASTS_MANIFEST_PATH="Modules/Package.swift"

FIREFOX_IOS_REPO="mozilla-mobile/firefox-ios"
FIREFOX_IOS_SHA="d97982a167c3e15393607e027eca7f92b53dcad8"
FIREFOX_IOS_MANIFEST_PATH="Package.swift"

isolated_workspace() {
  # Stand up a temp tree with the manifest copied in. Returns the package
  # directory on stdout. Caller is responsible for the RETURN trap that
  # cleans `${tmp}` up.
  local repo="$1"
  local sha="$2"
  local manifest_relative_path="$3"
  local tmp="$4"

  local package_dir="${tmp}/package"
  mkdir -p "${package_dir}"

  local manifest_url="https://raw.githubusercontent.com/${repo}/${sha}/${manifest_relative_path}"
  if ! curl --fail --silent --show-error --location --retry 3 \
      --output "${package_dir}/Package.swift" "${manifest_url}"; then
    echo "failed to download ${manifest_url}" >&2
    return 1
  fi

  echo "${package_dir}"
}

resolve_package() {
  local package_dir="$1"
  local cache_dir="$2"
  "${SWIFTERPM_BIN}" \
    --package-path "${package_dir}" \
    --scratch-path "${package_dir}/.build" \
    --cache-path "${cache_dir}" \
    --disable-package-info-cache \
    --quiet \
    resolve
}

swiftpm_accepts_lockfile() {
  local package_dir="$1"
  local cache_dir="$2"
  swift package \
    --package-path "${package_dir}" \
    --scratch-path "${package_dir}/.build" \
    --cache-path "${cache_dir}" \
    --disable-scm-to-registry-transformation \
    --force-resolved-versions \
    resolve >/dev/null 2>&1
}

pin_count() {
  local package_dir="$1"
  jq '.pins | length' "${package_dir}/Package.resolved"
}

scenario_resolves_firefox_ios() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  local package_dir
  package_dir="$(isolated_workspace \
    "${FIREFOX_IOS_REPO}" \
    "${FIREFOX_IOS_SHA}" \
    "${FIREFOX_IOS_MANIFEST_PATH}" \
    "${tmp}")" || return 1

  resolve_package "${package_dir}" "${tmp}/cache" || return 1
  swiftpm_accepts_lockfile "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "force-resolve=ok"
}

scenario_resolves_pocket_casts_ios() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  local package_dir
  package_dir="$(isolated_workspace \
    "${POCKET_CASTS_REPO}" \
    "${POCKET_CASTS_SHA}" \
    "${POCKET_CASTS_MANIFEST_PATH}" \
    "${tmp}")" || return 1

  resolve_package "${package_dir}" "${tmp}/cache" || return 1
  swiftpm_accepts_lockfile "${package_dir}" "${tmp}/swift-cache" || return 1

  echo "pins=$(pin_count "${package_dir}")"
  echo "force-resolve=ok"
}

Describe "swifterpm resolve against real-world manifests"
  It "resolves Firefox iOS root Package.swift and emits a SwiftPM-acceptable lockfile"
    When call scenario_resolves_firefox_ios
    The status should be success
    The output should match pattern "pins=*"
    The output should include "force-resolve=ok"
  End

  It "resolves Pocket Casts iOS Modules/Package.swift and emits a SwiftPM-acceptable lockfile"
    When call scenario_resolves_pocket_casts_ios
    The status should be success
    The output should match pattern "pins=*"
    The output should include "force-resolve=ok"
  End
End
