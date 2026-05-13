use std::{path::Path, process::Command};

use anyhow::{Context, Result, anyhow, bail};
use semver::Version;
use serde_json::Value;

#[derive(Debug, Clone)]
pub(crate) struct ManifestDependency {
    pub(crate) identity: String,
    pub(crate) location: String,
    pub(crate) requirement: Requirement,
}

#[derive(Debug, Clone)]
pub(crate) enum Requirement {
    Exact(Version),
    Range { lower: Version, upper: Version },
    Revision(String),
    Branch(String),
}

pub(crate) fn dump_package(package_dir: &Path) -> Result<Value> {
    let output = Command::new("swift")
        .args(["package", "dump-package"])
        .current_dir(package_dir)
        .output()
        .context("failed to run swift package dump-package")?;
    if !output.status.success() {
        bail!(
            "swift package dump-package failed:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    serde_json::from_slice(&output.stdout).context("failed to parse dump-package JSON")
}

pub(crate) fn parse_manifest_dependencies(manifest: &Value) -> Result<Vec<ManifestDependency>> {
    let mut dependencies = Vec::new();
    let Some(items) = manifest.get("dependencies").and_then(Value::as_array) else {
        return Ok(dependencies);
    };

    for item in items {
        let Some(source_control) = item.get("sourceControl").and_then(Value::as_array) else {
            continue;
        };
        for dependency in source_control {
            let identity = dependency
                .get("identity")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("sourceControl dependency is missing identity"))?
                .to_string();
            let location = dependency
                .pointer("/location/remote/0/urlString")
                .and_then(Value::as_str)
                .ok_or_else(|| anyhow!("{identity} is missing remote urlString"))?
                .to_string();
            let requirement = parse_requirement(
                dependency
                    .get("requirement")
                    .ok_or_else(|| anyhow!("{identity} is missing requirement"))?,
            )
            .with_context(|| format!("failed to parse requirement for {identity}"))?;
            dependencies.push(ManifestDependency {
                identity,
                location,
                requirement,
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
