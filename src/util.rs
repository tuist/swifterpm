use std::{
    fs::{self, OpenOptions},
    io,
    path::Path,
    process::Command,
};

use anyhow::{Result, bail};
use fs2::FileExt;
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

pub(crate) struct PathLock {
    file: fs::File,
}

impl Drop for PathLock {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

pub(crate) fn lock_path(path: &Path) -> Result<PathLock> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    file.lock_exclusive()?;
    Ok(PathLock { file })
}

pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("{} has no parent", path.display()))?;
    fs::create_dir_all(parent)?;
    let mut temp = tempfile::NamedTempFile::new_in(parent)?;
    io::Write::write_all(&mut temp, bytes)?;
    temp.persist(path)?;
    Ok(())
}
