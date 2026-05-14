create_git_package() {
  local repository="$1"
  local package_name="$2"
  local product_name="$3"
  local target_name="$4"
  local dependency_block="${5:-}"
  local target_dependency_block="${6:-}"
  local extra_targets="${7:-}"

  mkdir -p "${repository}/Sources/${target_name}"
  cat >"${repository}/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "${package_name}",
    products: [
        .library(name: "${product_name}", targets: ["${target_name}"]),
    ],
    dependencies: [
${dependency_block}
    ],
    targets: [
        .target(
            name: "${target_name}",
            dependencies: [
${target_dependency_block}
            ]
        )${extra_targets}
    ]
)
EOF
  cat >"${repository}/Sources/${target_name}/${target_name}.swift" <<EOF
public enum ${target_name} {
    public static let name = "${target_name}"
}
EOF
  init_git_repository "${repository}"
}

init_git_repository() {
  local repository="$1"
  git -C "${repository}" init -b main >/dev/null
  git -C "${repository}" config user.name "SwifterPM Tests"
  git -C "${repository}" config user.email "tests@swifterpm.local"
  git -C "${repository}" add .
  git -C "${repository}" commit -m "Initial package" >/dev/null
}

tag_repository() {
  local repository="$1"
  local version="$2"
  git -C "${repository}" tag "${version}"
}

commit_package_change() {
  local repository="$1"
  local file="$2"
  local message="$3"
  printf '\n// %s\n' "${message}" >>"${repository}/${file}"
  git -C "${repository}" add .
  git -C "${repository}" commit -m "${message}" >/dev/null
}

resolve_package() {
  local package="$1"
  local cache="$2"
  "${SWIFTERPM_BIN}" \
    --package-path "${package}" \
    --scratch-path "${package}/.build" \
    --cache-path "${cache}" \
    --disable-package-info-cache \
    --quiet \
    resolve
}

swiftpm_accepts_resolved_file() {
  local package="$1"
  swift package \
    --package-path "${package}" \
    --scratch-path "${package}/.build" \
    --disable-scm-to-registry-transformation \
    --force-resolved-versions \
    resolve >/dev/null 2>&1
}

pin_version() {
  local package="$1"
  local identity="$2"
  jq -r --arg identity "${identity}" '.pins[] | select(.identity == $identity) | .state.version // "none"' "${package}/Package.resolved"
}

pin_branch() {
  local package="$1"
  local identity="$2"
  jq -r --arg identity "${identity}" '.pins[] | select(.identity == $identity) | .state.branch // "none"' "${package}/Package.resolved"
}

pin_identities() {
  local package="$1"
  jq -r '.pins[].identity' "${package}/Package.resolved" | sort | tr '\n' ' '
}

scenario_prefers_stable_versions() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  local leaf="${tmp}/leaf"
  create_git_package "${leaf}" "Leaf" "Leaf" "Leaf"
  tag_repository "${leaf}" "1.0.0"
  commit_package_change "${leaf}" "Sources/Leaf/Leaf.swift" "Prerelease"
  tag_repository "${leaf}" "1.1.0-alpha"

  local root="${tmp}/root"
  mkdir -p "${root}/Sources/App"
  cat >"${root}/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Root",
    dependencies: [
        .package(url: "${leaf}", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Leaf", package: "leaf"),
            ]
        ),
    ]
)
EOF
  echo 'import Leaf; print(Leaf.name)' >"${root}/Sources/App/main.swift"

  resolve_package "${root}" "${tmp}/cache"
  swiftpm_accepts_resolved_file "${root}"

  echo "leaf=$(pin_version "${root}" "leaf")"
  echo "pins=$(pin_identities "${root}")"
  echo "force-resolve=ok"
}

scenario_matches_transitive_reachability() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  create_git_package "${tmp}/core" "Core" "Core" "Core"
  tag_repository "${tmp}/core" "1.0.0"
  create_git_package "${tmp}/testdep" "TestDep" "TestDep" "TestDep"
  tag_repository "${tmp}/testdep" "1.0.0"
  create_git_package "${tmp}/cli-only" "CliOnly" "CliOnly" "CliOnly"
  tag_repository "${tmp}/cli-only" "1.0.0"
  create_git_package "${tmp}/hook" "Hook" "Hook" "Hook"
  tag_repository "${tmp}/hook" "1.0.0"

  local b="${tmp}/b"
  mkdir -p "${b}/Sources/B" "${b}/Sources/BTool" "${b}/Tests/BTests"
  cat >"${b}/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "B",
    products: [
        .library(name: "B", targets: ["B"]),
    ],
    dependencies: [
        .package(url: "${tmp}/core", from: "1.0.0"),
        .package(url: "${tmp}/testdep", from: "1.0.0"),
        .package(url: "${tmp}/cli-only", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "B",
            dependencies: [
                .product(name: "Core", package: "core"),
            ]
        ),
        .testTarget(
            name: "BTests",
            dependencies: [
                .product(name: "TestDep", package: "testdep"),
            ]
        ),
        .executableTarget(
            name: "BTool",
            dependencies: [
                .product(name: "CliOnly", package: "cli-only"),
            ]
        ),
    ]
)
EOF
  echo 'import Core; public enum B { public static let name = Core.name }' >"${b}/Sources/B/B.swift"
  echo 'import CliOnly; print(CliOnly.name)' >"${b}/Sources/BTool/main.swift"
  echo 'import TestDep' >"${b}/Tests/BTests/BTests.swift"
  init_git_repository "${b}"
  tag_repository "${b}" "1.0.0"

  local a="${tmp}/a"
  create_git_package "${a}" "A" "A" "A" \
    "        .package(url: \"${b}\", from: \"1.0.0\"),
        .package(url: \"${tmp}/hook\", from: \"1.0.0\")," \
    "                .product(name: \"B\", package: \"b\"),"
  tag_repository "${a}" "1.0.0"

  local root="${tmp}/root"
  mkdir -p "${root}/Sources/App"
  cat >"${root}/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Root",
    dependencies: [
        .package(url: "${a}", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "A", package: "a"),
            ]
        ),
    ]
)
EOF
  echo 'import A; print(A.name)' >"${root}/Sources/App/main.swift"

  resolve_package "${root}" "${tmp}/cache"
  swiftpm_accepts_resolved_file "${root}"

  echo "pins=$(pin_identities "${root}")"
  echo "has-hook=$(jq -r '.pins | any(.identity == "hook")' "${root}/Package.resolved")"
  echo "has-cli-only=$(jq -r '.pins | any(.identity == "cli-only")' "${root}/Package.resolved")"
  echo "force-resolve=ok"
}

scenario_resolves_branch_pins() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  local branchdep="${tmp}/branchdep"
  create_git_package "${branchdep}" "BranchDep" "BranchDep" "BranchDep"

  local root="${tmp}/root"
  mkdir -p "${root}/Sources/App"
  cat >"${root}/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Root",
    dependencies: [
        .package(url: "${branchdep}", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "BranchDep", package: "branchdep"),
            ]
        ),
    ]
)
EOF
  echo 'import BranchDep; print(BranchDep.name)' >"${root}/Sources/App/main.swift"

  resolve_package "${root}" "${tmp}/cache"
  swiftpm_accepts_resolved_file "${root}"

  echo "branch=$(pin_branch "${root}" "branchdep")"
  echo "version=$(pin_version "${root}" "branchdep")"
  echo "force-resolve=ok"
}

Describe "swifterpm resolve"
  It "prefers stable versions over newer prereleases"
    When call scenario_prefers_stable_versions
    The status should be success
    The output should include "leaf=1.0.0"
    The output should include "pins=leaf "
    The output should include "force-resolve=ok"
  End

  It "matches SwiftPM reachability for direct and transitive dependencies"
    When call scenario_matches_transitive_reachability
    The status should be success
    The output should include "has-hook=true"
    The output should include "has-cli-only=false"
    The output should include "core"
    The output should include "testdep"
    The output should include "force-resolve=ok"
  End

  It "resolves branch requirements without a Package.resolved file"
    When call scenario_resolves_branch_pins
    The status should be success
    The output should include "branch=main"
    The output should include "version=none"
    The output should include "force-resolve=ok"
  End
End
