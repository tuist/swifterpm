use std::{fs, io, path::Path, process::Command};

use anyhow::{Result, bail};
use sha2::{Digest, Sha256};

pub(crate) fn command_output(command: &mut Command) -> Result<String> {
    let output = command.output()?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr));
    }
    Ok(String::from_utf8(output.stdout)?)
}

pub(crate) fn run(command: &mut Command) -> Result<()> {
    let output = command.output()?;
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr));
    }
    Ok(())
}

pub(crate) fn short_revision(revision: &str) -> String {
    revision.chars().take(12).collect()
}

pub(crate) fn stable_hash(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input);
    hex::encode(hasher.finalize())
}

pub(crate) fn replace_with_symlink(source: &Path, link: &Path) -> Result<()> {
    if link.symlink_metadata().is_ok() {
        if link.is_dir() && !link.is_symlink() {
            fs::remove_dir_all(link)?;
        } else {
            fs::remove_file(link)?;
        }
    }

    #[cfg(unix)]
    std::os::unix::fs::symlink(source, link)?;
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(source, link)?;
    Ok(())
}

pub(crate) fn flatten_single_directory(path: &Path) -> Result<()> {
    let entries = fs::read_dir(path)?.collect::<io::Result<Vec<_>>>()?;
    if entries.len() != 1 || !entries[0].file_type()?.is_dir() {
        return Ok(());
    }

    let nested = entries[0].path();
    let temp = path.with_extension("flattening");
    if temp.exists() {
        fs::remove_dir_all(&temp)?;
    }
    fs::rename(&nested, &temp)?;
    fs::remove_dir_all(path)?;
    fs::rename(temp, path)?;
    Ok(())
}
