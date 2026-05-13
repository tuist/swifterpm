use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use rayon::prelude::*;
use serde::Serialize;

use crate::{
    manifest::dump_package_json,
    resolved::{ResolvedPin, ResolvedPins, checkout_directory_name, is_source_control_kind},
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

    let checkouts_dir = scratch_dir.join("checkouts");
    let mut source_pins = resolved
        .pins
        .iter()
        .filter(|pin| is_source_control_kind(&pin.kind))
        .cloned()
        .collect::<Vec<_>>();
    source_pins.sort_by(|left, right| left.identity.cmp(&right.identity));

    let packages = source_pins
        .par_iter()
        .map(|pin| {
            let package_path = checkouts_dir.join(checkout_directory_name(pin));
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
    pin.identity
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '_'
            }
        })
        .collect()
}
