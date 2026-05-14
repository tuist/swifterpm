use std::{collections::BTreeSet, path::Path, process::Command};

use anyhow::{Context, Result, anyhow, bail};
use semver::Version;
use serde_json::Value;

#[derive(Debug, Clone)]
pub(crate) struct ManifestDependency {
    pub(crate) identity: String,
    pub(crate) kind: ManifestDependencyKind,
    pub(crate) location: String,
    pub(crate) requirement: Requirement,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum ManifestDependencyKind {
    SourceControl,
    Registry,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ManifestFileSystemDependency {
    pub(crate) identity: String,
    pub(crate) name: String,
    pub(crate) path: String,
}

#[derive(Debug, Clone)]
pub(crate) enum Requirement {
    Exact(Version),
    Range { lower: Version, upper: Version },
    Revision(String),
    Branch(String),
}

pub(crate) fn dump_package(package_dir: &Path, disable_sandbox: bool) -> Result<Value> {
    let output = dump_package_json(package_dir, disable_sandbox)?;
    serde_json::from_slice(&output).context("failed to parse dump-package JSON")
}

pub(crate) fn dump_package_json(package_dir: &Path, disable_sandbox: bool) -> Result<Vec<u8>> {
    let mut command = Command::new("swift");
    command.arg("package");
    if disable_sandbox {
        command.arg("--disable-sandbox");
    }
    let output = command
        .arg("dump-package")
        .current_dir(package_dir)
        .output()
        .context("failed to run swift package dump-package")?;
    if !output.status.success() {
        bail!(
            "swift package dump-package failed:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(output.stdout)
}

pub(crate) fn parse_manifest_dependencies(manifest: &Value) -> Result<Vec<ManifestDependency>> {
    let mut dependencies = Vec::new();
    let Some(items) = manifest.get("dependencies").and_then(Value::as_array) else {
        return Ok(dependencies);
    };

    for item in items {
        if let Some(source_control) = item.get("sourceControl").and_then(Value::as_array) {
            for dependency in source_control {
                let identity = dependency
                    .get("identity")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("sourceControl dependency is missing identity"))?
                    .to_string();
                let location = parse_source_control_location(dependency)
                    .ok_or_else(|| anyhow!("{identity} is missing source-control location"))?;
                let requirement = parse_requirement(
                    dependency
                        .get("requirement")
                        .ok_or_else(|| anyhow!("{identity} is missing requirement"))?,
                )
                .with_context(|| format!("failed to parse requirement for {identity}"))?;
                dependencies.push(ManifestDependency {
                    identity,
                    kind: ManifestDependencyKind::SourceControl,
                    location,
                    requirement,
                });
            }
        }

        if let Some(registry) = item.get("registry").and_then(Value::as_array) {
            for dependency in registry {
                let identity = dependency
                    .get("identity")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("registry dependency is missing identity"))?
                    .to_string();
                let requirement = parse_requirement(
                    dependency
                        .get("requirement")
                        .ok_or_else(|| anyhow!("{identity} is missing requirement"))?,
                )
                .with_context(|| format!("failed to parse requirement for {identity}"))?;
                dependencies.push(ManifestDependency {
                    location: identity.clone(),
                    identity,
                    kind: ManifestDependencyKind::Registry,
                    requirement,
                });
            }
        }
    }

    Ok(dependencies)
}

fn parse_source_control_location(dependency: &Value) -> Option<String> {
    dependency
        .pointer("/location/remote/0/urlString")
        .and_then(Value::as_str)
        .or_else(|| {
            dependency
                .pointer("/location/local/0")
                .and_then(Value::as_str)
        })
        .map(ToString::to_string)
}

pub(crate) fn parse_required_manifest_dependencies(
    manifest: &Value,
) -> Result<Vec<ManifestDependency>> {
    let dependencies = parse_manifest_dependencies(manifest)?;
    let references = active_dependency_references(manifest);
    if references.is_empty() {
        return Ok(Vec::new());
    }

    Ok(dependencies
        .into_iter()
        .filter(|dependency| {
            dependency_reference_names(dependency)
                .into_iter()
                .any(|name| references.contains(&name))
        })
        .collect())
}

fn active_dependency_references(manifest: &Value) -> BTreeSet<String> {
    let mut references = BTreeSet::new();
    let Some(targets) = manifest.get("targets").and_then(Value::as_array) else {
        return references;
    };
    let target_names = targets
        .iter()
        .filter_map(|target| target.get("name").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let mut pending_targets = manifest
        .get("products")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|product| product.get("targets").and_then(Value::as_array))
        .flatten()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    pending_targets.extend(
        targets
            .iter()
            .filter(|target| target.get("type").and_then(Value::as_str) == Some("test"))
            .filter_map(|target| target.get("name").and_then(Value::as_str)),
    );
    let mut visited_targets = BTreeSet::new();

    while let Some(target_name) = pending_targets.pop() {
        if !visited_targets.insert(target_name) {
            continue;
        }
        let Some(target) = targets
            .iter()
            .find(|target| target.get("name").and_then(Value::as_str) == Some(target_name))
        else {
            continue;
        };
        let Some(dependencies) = target.get("dependencies").and_then(Value::as_array) else {
            continue;
        };
        for dependency in dependencies {
            if let Some(product) = dependency.get("product").and_then(Value::as_array) {
                let product_name = product.first().and_then(Value::as_str);
                let package_name = product.get(1).and_then(Value::as_str);
                if let Some(package_name) = package_name.or(product_name) {
                    references.insert(normalize_dependency_reference(package_name));
                }
            }
            if let Some(by_name) = dependency.get("byName").and_then(Value::as_array) {
                if let Some(name) = by_name.first().and_then(Value::as_str) {
                    if target_names.contains(name) {
                        pending_targets.push(name);
                    } else {
                        references.insert(normalize_dependency_reference(name));
                    }
                }
            }
        }
    }

    references
}

fn dependency_reference_names(dependency: &ManifestDependency) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    names.insert(normalize_dependency_reference(&dependency.identity));
    if let Some((_, name)) = dependency.identity.rsplit_once('.') {
        names.insert(normalize_dependency_reference(name));
    }
    if dependency.kind == ManifestDependencyKind::SourceControl {
        if let Some(name) = dependency
            .location
            .trim_end_matches('/')
            .trim_end_matches(".git")
            .rsplit('/')
            .next()
        {
            names.insert(normalize_dependency_reference(name));
        }
    }
    names
}

fn normalize_dependency_reference(name: &str) -> String {
    name.trim_end_matches(".git").to_ascii_lowercase()
}

pub(crate) fn parse_manifest_file_system_dependencies(
    manifest: &Value,
) -> Result<Vec<ManifestFileSystemDependency>> {
    let mut dependencies = Vec::new();
    let Some(items) = manifest.get("dependencies").and_then(Value::as_array) else {
        return Ok(dependencies);
    };

    for item in items {
        let Some(file_system) = item.get("fileSystem").and_then(Value::as_array) else {
            continue;
        };
        for dependency in file_system {
            let identity = dependency
                .get("identity")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("fileSystem dependency is missing identity"))?
                .to_string();
            let path = dependency
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("{identity} is missing path"))?
                .to_string();
            let name = dependency
                .get("nameForTargetDependencyResolutionOnly")
                .and_then(Value::as_str)
                .unwrap_or(&identity)
                .to_string();
            dependencies.push(ManifestFileSystemDependency {
                identity,
                name,
                path,
            });
        }
    }

    Ok(dependencies)
}

pub(crate) fn parse_requirement(requirement: &Value) -> Result<Requirement> {
    if let Some(exact) = requirement
        .get("exact")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(Value::as_str)
    {
        return Ok(Requirement::Exact(Version::parse(exact)?));
    }
    if let Some(range) = requirement
        .get("range")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
    {
        let lower = range
            .get("lowerBound")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("range is missing lowerBound"))?;
        let upper = range
            .get("upperBound")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("range is missing upperBound"))?;
        return Ok(Requirement::Range {
            lower: Version::parse(lower)?,
            upper: Version::parse(upper)?,
        });
    }
    if let Some(revision) = requirement
        .get("revision")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(Value::as_str)
    {
        return Ok(Requirement::Revision(revision.to_string()));
    }
    if let Some(branch) = requirement
        .get("branch")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(Value::as_str)
    {
        return Ok(Requirement::Branch(branch.to_string()));
    }
    bail!("unsupported requirement shape: {requirement}");
}
