use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use rayon::prelude::*;
use serde::Serialize;
use serde_json::Value;

use crate::{
    manifest::{dump_package_json, parse_manifest_file_system_dependencies},
    resolved::{
        ResolvedPin, ResolvedPins, checkout_directory_name, is_registry_kind,
        is_source_control_kind, registry_download_subpath,
    },
    util::{atomic_write, lock_path, stable_hash},
};

#[derive(Debug, Serialize)]
struct PackageInfoIndex {
    schema_version: u8,
    generated_at_unix: u64,
    root: PackageInfoEntry,
    packages: Vec<PackageInfoEntry>,
}

#[derive(Debug, Serialize)]
struct PackageInfoEntry {
    identity: String,
    kind: String,
    location: String,
    version: Option<String>,
    revision: Option<String>,
    package_path: String,
    package_info_path: String,
}

pub(crate) fn write_package_info_cache(
    package_dir: &Path,
    scratch_dir: &Path,
    resolved: &ResolvedPins,
    cache_dir: Option<&Path>,
    disable_sandbox: bool,
    quiet: bool,
) -> Result<()> {
    let cache_dir = cache_dir
        .map(Path::to_path_buf)
        .unwrap_or_else(|| scratch_dir.join("swifterpm/package-info"));
    let _scratch_lock = lock_path(&scratch_dir.join(".swifterpm.lock"))?;
    let _cache_lock = lock_path(&cache_dir.join(".swifterpm.lock"))?;
    fs::create_dir_all(cache_dir.join("packages"))?;

    let root_path = cache_dir.join("root.json");
    write_dump_package_json(package_dir, &root_path, disable_sandbox).with_context(|| {
        format!(
            "failed to cache root Package.swift at {}",
            package_dir.display()
        )
    })?;
    let root_manifest: Value = serde_json::from_slice(&fs::read(&root_path)?)?;

    let mut package_pins = resolved
        .pins
        .iter()
        .filter(|pin| is_source_control_kind(&pin.kind) || is_registry_kind(&pin.kind))
        .cloned()
        .collect::<Vec<_>>();
    package_pins.sort_by(|left, right| left.identity.cmp(&right.identity));

    let mut packages = package_pins
        .par_iter()
        .map(|pin| {
            let package_path = package_path_for_pin(scratch_dir, pin)?;
            let package_info_path = cache_dir.join("packages").join(format!(
                "{}-{}.json",
                file_safe_identity(pin),
                entry_hash(pin)
            ));
            write_dump_package_json(&package_path, &package_info_path, disable_sandbox)
                .with_context(|| format!("failed to cache Package.swift for {}", pin.identity))?;
            Ok(package_entry(pin, package_path, package_info_path))
        })
        .collect::<Result<Vec<_>>>()?;

    let mut local_dependencies = parse_manifest_file_system_dependencies(&root_manifest)?;
    local_dependencies.sort_by(|left, right| left.identity.cmp(&right.identity));
    for dependency in local_dependencies {
        let package_path = PathBuf::from(&dependency.path);
        let package_info_path = cache_dir.join("packages").join(format!(
            "{}-{}.json",
            file_safe_name(&dependency.identity),
            stable_hash(&dependency.path)
                .chars()
                .take(16)
                .collect::<String>()
        ));
        write_dump_package_json(&package_path, &package_info_path, disable_sandbox).with_context(
            || format!("failed to cache Package.swift for {}", dependency.identity),
        )?;
        packages.push(PackageInfoEntry {
            identity: dependency.identity,
            kind: "fileSystem".to_string(),
            location: dependency.path,
            version: None,
            revision: None,
            package_path: package_path.display().to_string(),
            package_info_path: package_info_path.display().to_string(),
        });
    }

    let index = PackageInfoIndex {
        schema_version: 1,
        generated_at_unix: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        root: PackageInfoEntry {
            identity: "root".to_string(),
            kind: "root".to_string(),
            location: package_dir.display().to_string(),
            version: None,
            revision: resolved.origin_hash.clone(),
            package_path: package_dir.display().to_string(),
            package_info_path: root_path.display().to_string(),
        },
        packages,
    };

    let mut bytes = serde_json::to_vec_pretty(&index)?;
    writeln!(bytes)?;
    atomic_write(&cache_dir.join("index.json"), &bytes)?;

    if !quiet {
        println!("cached package manifest JSON into {}", cache_dir.display());
    }
    Ok(())
}

fn package_path_for_pin(scratch_dir: &Path, pin: &ResolvedPin) -> Result<PathBuf> {
    if is_registry_kind(&pin.kind) {
        Ok(scratch_dir
            .join("registry/downloads")
            .join(registry_download_subpath(pin)?))
    } else {
        Ok(scratch_dir
            .join("checkouts")
            .join(checkout_directory_name(pin)))
    }
}

fn write_dump_package_json(
    package_dir: &Path,
    destination: &Path,
    disable_sandbox: bool,
) -> Result<()> {
    let bytes = dump_package_json(package_dir, disable_sandbox)?;
    atomic_write(destination, &bytes)
}

fn package_entry(
    pin: &ResolvedPin,
    package_path: PathBuf,
    package_info_path: PathBuf,
) -> PackageInfoEntry {
    PackageInfoEntry {
        identity: pin.identity.clone(),
        kind: pin.kind.clone(),
        location: pin.location.clone(),
        version: pin.state.version.clone(),
        revision: pin.state.revision.clone(),
        package_path: package_path.display().to_string(),
        package_info_path: package_info_path.display().to_string(),
    }
}

fn entry_hash(pin: &ResolvedPin) -> String {
    let input = format!(
        "{}:{}:{}",
        pin.location,
        pin.state.version.as_deref().unwrap_or_default(),
        pin.state.revision.as_deref().unwrap_or_default()
    );
    stable_hash(&input).chars().take(16).collect()
}

fn file_safe_identity(pin: &ResolvedPin) -> String {
    file_safe_name(&pin.identity)
}

fn file_safe_name(name: &str) -> String {
    name.chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect()
}
