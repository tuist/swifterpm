use std::{
    fs,
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
    resolved::{ResolvedPin, ResolvedPins, checkout_directory_name, is_source_control_kind},
    util::{atomic_write, flatten_single_directory, lock_path, replace_with_symlink, run},
};

pub(crate) fn restore_package(
    scratch_dir: &Path,
    cache: &Cache,
    resolved: &ResolvedPins,
    quiet: bool,
) -> Result<()> {
    let _scratch_lock = lock_path(&scratch_dir.join(".swifterpm.lock"))?;
    let checkouts = scratch_dir.join("checkouts");
    fs::create_dir_all(&checkouts)?;

    let pins = resolved
        .pins
        .iter()
        .filter(|pin| is_source_control_kind(&pin.kind))
        .cloned()
        .collect::<Vec<_>>();
    let skipped = resolved.pins.len() - pins.len();
    let restored = pins
        .par_iter()
        .map(|pin| {
            let source = ensure_source(cache, pin)
                .with_context(|| format!("failed to materialize {}", pin.identity))?;
            let checkout = checkouts.join(checkout_directory_name(pin));
            replace_with_symlink(&source, &checkout)?;
            Ok((pin.identity.clone(), source))
        })
        .collect::<Result<Vec<_>>>()?;

    if !quiet {
        for (identity, source) in &restored {
            println!("restored {} -> {}", identity, source.display());
        }
    }
    write_workspace_state(scratch_dir, resolved)?;

    if !quiet {
        println!(
            "restored {} source-control packages into {}",
            restored.len(),
            checkouts.display()
        );
        if skipped > 0 {
            println!("skipped {skipped} non-source-control pins");
        }
    }
    Ok(())
}

fn write_workspace_state(scratch_dir: &Path, resolved: &ResolvedPins) -> Result<()> {
    let mut dependencies = Vec::new();
    for pin in &resolved.pins {
        if !is_source_control_kind(&pin.kind) {
            continue;
        }

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
    }

    let state = json!({
        "object": {
            "artifacts": [],
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

fn ensure_source(cache: &Cache, pin: &ResolvedPin) -> Result<PathBuf> {
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
            return Ok(());
        }
        let url = format!(
            "https://api.github.com/repos/{}/{}/tarball/{}",
            github.owner, github.repo, revision
        );
        let client = reqwest::blocking::Client::builder()
            .user_agent("swifterpm/0.1")
            .build()?;
        let mut request = client.get(url);
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
    let git_dir = destination.join(".git");
    if git_dir.exists() {
        fs::remove_dir_all(git_dir)?;
    }
    Ok(())
}
