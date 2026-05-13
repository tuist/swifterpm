use std::{fs, io::Write, path::Path};

#[cfg(test)]
use std::path::PathBuf;

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ResolvedPins {
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "originHash")]
    pub(crate) origin_hash: Option<String>,
    pub(crate) pins: Vec<ResolvedPin>,
    pub(crate) version: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ResolvedPin {
    pub(crate) identity: String,
    pub(crate) kind: String,
    pub(crate) location: String,
    pub(crate) state: ResolvedState,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct ResolvedState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) revision: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) version: Option<String>,
}

impl ResolvedPin {
    pub(crate) fn revision(&self) -> Result<&str> {
        self.state
            .revision
            .as_deref()
            .ok_or_else(|| anyhow!("{} does not have a source-control revision", self.identity))
    }
}

pub(crate) fn read_resolved_file(package_dir: &Path) -> Result<ResolvedPins> {
    let path = package_dir.join("Package.resolved");
    let file = fs::File::open(&path)?;
    Ok(serde_json::from_reader(file)?)
}

pub(crate) fn write_resolved_file(package_dir: &Path, resolved: &ResolvedPins) -> Result<()> {
    let path = package_dir.join("Package.resolved");
    let mut file = fs::File::create(&path)?;
    serde_json::to_writer_pretty(&mut file, resolved)?;
    writeln!(file)?;
    Ok(())
}

pub(crate) fn print_resolution(resolved: &ResolvedPins) {
    for pin in &resolved.pins {
        if let Some(version) = &pin.state.version {
            println!(
                "{} {} {} {}",
                pin.identity,
                version,
                pin.state.revision.as_deref().unwrap_or("<unknown>"),
                pin.location
            );
        } else {
            println!(
                "{} {} {}",
                pin.identity,
                pin.state.revision.as_deref().unwrap_or("<unknown>"),
                pin.location
            );
        }
    }
}

pub(crate) fn is_source_control_kind(kind: &str) -> bool {
    matches!(kind, "remoteSourceControl" | "sourceControl")
}

pub(crate) fn checkout_directory_name(pin: &ResolvedPin) -> String {
    pin.location
        .trim_end_matches(".git")
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(&pin.identity)
        .to_string()
}

#[cfg(test)]
pub(crate) fn cache_test_path(cache_root: PathBuf, pin: &ResolvedPin) -> String {
    use crate::cache::Cache;

    let cache = Cache { root: cache_root };
    cache
        .source_path(pin)
        .unwrap()
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned()
}
