use std::{fs, path::PathBuf};

use anyhow::{Result, anyhow};

use crate::{
    resolved::ResolvedPin,
    util::{short_revision, stable_hash},
};

#[derive(Debug, Clone)]
pub(crate) struct Cache {
    pub(crate) root: PathBuf,
}

impl Cache {
    pub(crate) fn new(root: Option<PathBuf>) -> Result<Self> {
        let root = match root {
            Some(root) => root,
            None => dirs::cache_dir()
                .ok_or_else(|| anyhow!("could not find user cache directory"))?
                .join("swifterpm"),
        };
        fs::create_dir_all(root.join("sources"))?;
        fs::create_dir_all(root.join("archives"))?;
        fs::create_dir_all(root.join("metadata/remotes"))?;
        fs::create_dir_all(root.join("virtual/checkouts"))?;
        Ok(Self { root })
    }

    pub(crate) fn source_path(&self, pin: &ResolvedPin) -> Result<PathBuf> {
        let version = pin
            .state
            .version
            .clone()
            .or_else(|| pin.state.branch.clone())
            .unwrap_or_else(|| "revision".to_string());
        Ok(self.root.join("sources").join(&pin.identity).join(format!(
            "{}-{}",
            version,
            short_revision(pin.revision()?)
        )))
    }

    pub(crate) fn archive_path(&self, url: &str, revision: &str) -> PathBuf {
        self.root.join("archives").join(format!(
            "{}-{}.tar.gz",
            stable_hash(url),
            short_revision(revision)
        ))
    }

    pub(crate) fn remote_versions_path(&self, location: &str) -> PathBuf {
        self.root
            .join("metadata/remotes")
            .join(format!("{}.json", stable_hash(location)))
    }
}
