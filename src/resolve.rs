use std::{fs, path::Path};

use anyhow::{Result, anyhow, bail};
use semver::Version;
use sha2::{Digest, Sha256};

use crate::{
    cache::Cache,
    manifest::{Requirement, dump_package, parse_manifest_dependencies},
    remote::{remote_versions, resolve_named_ref},
    resolved::{ResolvedPin, ResolvedPins, ResolvedState},
};

pub(crate) fn resolve_package(package_dir: &Path, cache: &Cache) -> Result<ResolvedPins> {
    let manifest = dump_package(package_dir)?;
    let dependencies = parse_manifest_dependencies(&manifest)?;
    if dependencies.is_empty() {
        bail!("no sourceControl dependencies found in Package.swift");
    }

    let mut pins = Vec::new();
    for dependency in dependencies {
        let pin = resolve_dependency(&dependency, cache)
            .map_err(|error| anyhow!("failed to resolve {}: {error}", dependency.identity))?;
        pins.push(pin);
    }
    pins.sort_by(|left, right| left.identity.cmp(&right.identity));

    Ok(ResolvedPins {
        origin_hash: Some(origin_hash(package_dir)?),
        pins,
        version: 3,
    })
}

fn resolve_dependency(
    dependency: &crate::manifest::ManifestDependency,
    cache: &Cache,
) -> Result<ResolvedPin> {
    let state = match &dependency.requirement {
        Requirement::Revision(revision) => ResolvedState {
            branch: None,
            revision: Some(revision.clone()),
            version: None,
        },
        Requirement::Branch(branch) => {
            let revision = resolve_named_ref(&dependency.location, branch)?;
            ResolvedState {
                branch: Some(branch.clone()),
                revision: Some(revision),
                version: None,
            }
        }
        Requirement::Exact(version) => {
            let remote_version = remote_versions(&dependency.location, cache)?
                .into_iter()
                .find(|candidate| candidate.version == *version)
                .ok_or_else(|| anyhow!("version {version} was not found"))?;
            resolved_state_for_version(remote_version.version, remote_version.revision)
        }
        Requirement::Range { lower, upper } => {
            let remote_version = remote_versions(&dependency.location, cache)?
                .into_iter()
                .filter(|candidate| candidate.version >= *lower && candidate.version < *upper)
                .max_by(|left, right| left.version.cmp(&right.version))
                .ok_or_else(|| anyhow!("no version found in range [{lower}, {upper})"))?;
            resolved_state_for_version(remote_version.version, remote_version.revision)
        }
    };

    Ok(ResolvedPin {
        identity: dependency.identity.clone(),
        kind: "remoteSourceControl".to_string(),
        location: dependency.location.clone(),
        state,
    })
}

fn resolved_state_for_version(version: Version, revision: String) -> ResolvedState {
    ResolvedState {
        branch: None,
        revision: Some(revision),
        version: Some(version.to_string()),
    }
}

fn origin_hash(package_dir: &Path) -> Result<String> {
    let manifest = fs::read(package_dir.join("Package.swift"))?;
    let mut hasher = Sha256::new();
    hasher.update(manifest);
    Ok(hex::encode(hasher.finalize()))
}
