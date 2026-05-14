use std::{
    fs::{self, DirEntry},
    io::Write,
    path::{Path, PathBuf},
    process::Command,
};

use anyhow::{Context, Result, anyhow};
use flate2::read::GzDecoder;
use rayon::prelude::*;
use serde_json::{Value, json};

use crate::{
    cache::Cache,
    github::{GitHubRepo, github_token},
    manifest::{dump_package, parse_manifest_file_system_dependencies},
    registry::{RegistryConfig, download_registry_archive},
    resolved::{
        ResolvedPin, ResolvedPins, checkout_directory_name, is_registry_kind,
        is_source_control_kind, registry_download_subpath,
    },
    util::{
        atomic_write, flatten_single_directory, http_client, lock_path,
        replace_with_symlinked_directory_contents, run,
    },
};

pub(crate) fn restore_package(
    scratch_dir: &Path,
    cache: &Cache,
    registry_config: &RegistryConfig,
    resolved: &ResolvedPins,
    quiet: bool,
) -> Result<()> {
    let _scratch_lock = lock_path(&scratch_dir.join(".swifterpm.lock"))?;
    let checkouts = scratch_dir.join("checkouts");
    let registry_downloads = scratch_dir.join("registry/downloads");
    fs::create_dir_all(&checkouts)?;
    fs::create_dir_all(&registry_downloads)?;

    let source_pins = resolved
        .pins
        .iter()
        .filter(|pin| is_source_control_kind(&pin.kind))
        .cloned()
        .collect::<Vec<_>>();
    let registry_pins = resolved
        .pins
        .iter()
        .filter(|pin| is_registry_kind(&pin.kind))
        .cloned()
        .collect::<Vec<_>>();
    let skipped = resolved.pins.len() - source_pins.len() - registry_pins.len();
    let restored_sources = source_pins
        .par_iter()
        .map(|pin| {
            let source = ensure_source(cache, pin)
                .with_context(|| format!("failed to materialize {}", pin.identity))?;
            let checkout = checkouts.join(checkout_directory_name(pin));
            replace_with_symlinked_directory_contents(&source, &checkout)?;
            Ok((pin.identity.clone(), source))
        })
        .collect::<Result<Vec<_>>>()?;
    let restored_registry = registry_pins
        .par_iter()
        .map(|pin| {
            let source = ensure_registry_source(cache, registry_config, pin)
                .with_context(|| format!("failed to materialize {}", pin.identity))?;
            let download = registry_downloads.join(registry_download_subpath(pin)?);
            replace_with_symlinked_directory_contents(&source, &download)?;
            Ok((pin.identity.clone(), source))
        })
        .collect::<Result<Vec<_>>>()?;

    if !quiet {
        for (identity, source) in &restored_sources {
            println!("restored {} -> {}", identity, source.display());
        }
        for (identity, source) in &restored_registry {
            println!("restored {} -> {}", identity, source.display());
        }
    }
    if !quiet {
        println!(
            "restored {} source-control packages into {}",
            restored_sources.len(),
            checkouts.display()
        );
        println!(
            "restored {} registry packages into {}",
            restored_registry.len(),
            registry_downloads.display()
        );
        if skipped > 0 {
            println!("skipped {skipped} unsupported pins");
        }
    }
    Ok(())
}

pub(crate) fn write_workspace_state(
    package_dir: &Path,
    scratch_dir: &Path,
    resolved: &ResolvedPins,
    disable_sandbox: bool,
) -> Result<()> {
    let mut dependencies = Vec::new();
    let mut artifacts = Vec::new();
    for pin in &resolved.pins {
        if is_source_control_kind(&pin.kind) {
            let mut checkout_state = serde_json::Map::new();
            if let Some(branch) = &pin.state.branch {
                checkout_state.insert("branch".to_string(), json!(branch));
            }
            checkout_state.insert("revision".to_string(), json!(pin.revision()?));
            if let Some(version) = &pin.state.version {
                checkout_state.insert("version".to_string(), json!(version));
            }

            dependencies.push(json!({
                "basedOn": null,
                "packageRef": {
                    "identity": pin.identity,
                    "kind": pin.kind,
                    "location": pin.location,
                    "name": checkout_directory_name(pin)
                },
                "state": {
                    "checkoutState": Value::Object(checkout_state),
                    "name": "sourceControlCheckout"
                },
                "subpath": checkout_directory_name(pin)
            }));

            artifacts.extend(discover_artifacts(scratch_dir, pin)?);
        } else if is_registry_kind(&pin.kind) {
            dependencies.push(json!({
                "basedOn": null,
                "packageRef": {
                    "identity": pin.identity,
                    "kind": "registry",
                    "location": pin.identity,
                    "name": pin.identity
                },
                "state": {
                    "name": "registryDownload",
                    "version": pin.version()?
                },
                "subpath": registry_download_subpath(pin)?
            }));

            artifacts.extend(discover_artifacts(scratch_dir, pin)?);
        }
    }

    let manifest = dump_package(package_dir, disable_sandbox).with_context(|| {
        format!(
            "failed to inspect Package.swift at {}",
            package_dir.display()
        )
    })?;
    for dependency in parse_manifest_file_system_dependencies(&manifest)? {
        let identity = dependency.identity;
        let name = dependency.name;
        let path = dependency.path;
        dependencies.push(json!({
            "basedOn": null,
            "packageRef": {
                "identity": identity.clone(),
                "kind": "fileSystem",
                "location": path.clone(),
                "name": name,
                "path": path.clone()
            },
            "state": {
                "name": "fileSystem",
                "path": path.clone()
            },
            "subpath": identity
        }));
    }

    let state = json!({
        "object": {
            "artifacts": artifacts,
            "dependencies": dependencies,
            "prebuilts": []
        },
        "version": 7
    });
    fs::create_dir_all(scratch_dir)?;
    let path = scratch_dir.join("workspace-state.json");
    let mut bytes = serde_json::to_vec_pretty(&state)?;
    writeln!(bytes)?;
    atomic_write(&path, &bytes)?;
    Ok(())
}

fn discover_artifacts(scratch_dir: &Path, pin: &ResolvedPin) -> Result<Vec<Value>> {
    let artifacts_dir = scratch_dir.join("artifacts").join(&pin.identity);
    if !artifacts_dir.exists() {
        return Ok(Vec::new());
    }

    let mut artifacts = Vec::new();
    collect_artifacts(&artifacts_dir, pin, &mut artifacts)?;
    Ok(artifacts)
}

fn collect_artifacts(
    directory: &Path,
    pin: &ResolvedPin,
    artifacts: &mut Vec<Value>,
) -> Result<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        if path.extension().and_then(|extension| extension.to_str()) == Some("xcframework") {
            let target_name = path
                .file_stem()
                .and_then(|name| name.to_str())
                .unwrap_or(&pin.identity);
            artifacts.push(json!({
                "kind": { "xcframework": {} },
                "packageRef": {
                    "identity": pin.identity,
                    "kind": pin.kind,
                    "location": pin.location,
                    "name": checkout_directory_name(pin)
                },
                "path": path.display().to_string(),
                "targetName": target_name
            }));
        } else {
            collect_artifacts(&path, pin, artifacts)?;
        }
    }
    Ok(())
}

pub(crate) fn ensure_source(cache: &Cache, pin: &ResolvedPin) -> Result<PathBuf> {
    let destination = cache.source_path(pin)?;
    if destination.join("Package.swift").exists() {
        return Ok(destination);
    }
    let _lock = cache.lock("sources", &destination.to_string_lossy())?;
    if destination.join("Package.swift").exists() {
        return Ok(destination);
    }
    if destination.exists() {
        fs::remove_dir_all(&destination)?;
    }
    let parent = destination
        .parent()
        .ok_or_else(|| anyhow!("cache destination has no parent"))?;
    fs::create_dir_all(parent)?;

    let temp = tempfile::tempdir_in(parent)?;

    if download_github_archive(cache, pin, temp.path()).is_err() {
        reset_directory(temp.path())?;
        shallow_fetch_checkout(pin, temp.path())?;
    }

    match fs::rename(temp.keep(), &destination) {
        Ok(()) => {}
        Err(error) if destination.join("Package.swift").exists() => {
            let _ = error;
        }
        Err(error) => return Err(error.into()),
    }
    Ok(destination)
}

pub(crate) fn ensure_registry_source(
    cache: &Cache,
    registry_config: &RegistryConfig,
    pin: &ResolvedPin,
) -> Result<PathBuf> {
    let destination = cache.source_path(pin)?;
    if destination.join("Package.swift").exists() {
        return Ok(destination);
    }
    let _lock = cache.lock("sources", &destination.to_string_lossy())?;
    if destination.join("Package.swift").exists() {
        return Ok(destination);
    }
    if destination.exists() {
        fs::remove_dir_all(&destination)?;
    }
    let parent = destination
        .parent()
        .ok_or_else(|| anyhow!("cache destination has no parent"))?;
    fs::create_dir_all(parent)?;

    let temp = tempfile::tempdir_in(parent)?;
    download_registry_archive(
        cache,
        registry_config,
        &pin.identity,
        pin.version()?,
        temp.path(),
    )?;

    match fs::rename(temp.keep(), &destination) {
        Ok(()) => {}
        Err(error) if destination.join("Package.swift").exists() => {
            let _ = error;
        }
        Err(error) => return Err(error.into()),
    }
    Ok(destination)
}

fn download_github_archive(cache: &Cache, pin: &ResolvedPin, destination: &Path) -> Result<()> {
    let github = GitHubRepo::parse(&pin.location)?;
    let revision = pin.revision()?;
    let archive_path = cache.archive_path(&pin.location, revision);
    if !archive_path.exists() {
        let _lock = cache.lock("archives", &archive_path.to_string_lossy())?;
        if archive_path.exists() {
            let file = fs::File::open(&archive_path)?;
            let gzip = GzDecoder::new(file);
            let mut archive = tar::Archive::new(gzip);
            archive.unpack(destination)?;
            flatten_single_directory(destination)?;
            reject_archive_with_submodules(destination)?;
            return Ok(());
        }
        let url = format!(
            "https://api.github.com/repos/{}/{}/tarball/{}",
            github.owner, github.repo, revision
        );
        let mut request = http_client().get(url);
        if let Some(token) = github_token() {
            request = request.bearer_auth(token);
        }
        let response = request.send()?.error_for_status()?;
        let bytes = response.bytes()?;
        atomic_write(&archive_path, &bytes)?;
    }

    let file = fs::File::open(&archive_path)?;
    let gzip = GzDecoder::new(file);
    let mut archive = tar::Archive::new(gzip);
    archive.unpack(destination)?;
    flatten_single_directory(destination)?;
    reject_archive_with_submodules(destination)?;
    Ok(())
}

fn shallow_fetch_checkout(pin: &ResolvedPin, destination: &Path) -> Result<()> {
    let revision = pin.revision()?;
    fs::create_dir_all(destination)?;
    run(Command::new("git").arg("init").arg(destination))?;
    run(Command::new("git").arg("-C").arg(destination).args([
        "remote",
        "add",
        "origin",
        &pin.location,
    ]))?;
    run(Command::new("git").arg("-C").arg(destination).args([
        "fetch",
        "--depth=1",
        "origin",
        revision,
    ]))?;
    run(Command::new("git").arg("-C").arg(destination).args([
        "checkout",
        "--detach",
        "FETCH_HEAD",
    ]))?;
    run(Command::new("git").arg("-C").arg(destination).args([
        "submodule",
        "update",
        "--init",
        "--recursive",
    ]))?;
    let git_dir = destination.join(".git");
    if git_dir.exists() {
        fs::remove_dir_all(git_dir)?;
    }
    Ok(())
}

fn reject_archive_with_submodules(destination: &Path) -> Result<()> {
    if destination.join(".gitmodules").exists() {
        anyhow::bail!(
            "{} declares git submodules, which GitHub source archives do not include",
            destination.display()
        );
    }
    Ok(())
}

fn reset_directory(path: &Path) -> Result<()> {
    if path.exists() {
        for entry in fs::read_dir(path)? {
            remove_entry(entry?)?;
        }
    }
    fs::create_dir_all(path)?;
    Ok(())
}

fn remove_entry(entry: DirEntry) -> Result<()> {
    let path = entry.path();
    if entry.file_type()?.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn archive_checkouts_with_submodules_are_rejected() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("Package.swift"),
            "// swift-tools-version: 6.0\n",
        )
        .unwrap();
        fs::write(
            temp.path().join(".gitmodules"),
            "[submodule \"Sources/CDependency\"]\n",
        )
        .unwrap();

        let error = reject_archive_with_submodules(temp.path()).unwrap_err();

        assert!(error.to_string().contains("declares git submodules"));
    }

    #[test]
    fn reset_directory_removes_existing_archive_contents() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("Sources")).unwrap();
        fs::write(temp.path().join("Sources/file.swift"), "").unwrap();
        fs::write(temp.path().join(".gitmodules"), "").unwrap();

        reset_directory(temp.path()).unwrap();

        assert!(fs::read_dir(temp.path()).unwrap().next().is_none());
    }
}
