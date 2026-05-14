use std::{
    fs::{self, OpenOptions},
    io,
    path::Path,
    process::Command,
    sync::OnceLock,
};

use anyhow::{Result, bail};
use fs2::FileExt;
use reqwest::blocking::Client;
use sha2::{Digest, Sha256};

/// Shared HTTPS client. Reuses TLS connections across calls — relevant when we
/// fan out parallel fetches to api.github.com and codeload.github.com.
pub(crate) fn http_client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .user_agent("swifterpm/0.1")
            .pool_max_idle_per_host(16)
            .build()
            .expect("failed to construct HTTP client")
    })
}

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

pub(crate) fn replace_with_symlinked_directory_contents(
    source: &Path,
    destination: &Path,
) -> Result<()> {
    if destination.symlink_metadata().is_ok() {
        remove_path(destination)?;
    }
    fs::create_dir_all(destination)?;

    for entry in fs::read_dir(source)? {
        let entry = entry?;
        symlink_path(&entry.path(), &destination.join(entry.file_name()))?;
    }
    Ok(())
}

fn symlink_path(source: &Path, link: &Path) -> Result<()> {
    #[cfg(unix)]
    std::os::unix::fs::symlink(source, link)?;
    #[cfg(windows)]
    {
        if source.is_dir() {
            std::os::windows::fs::symlink_dir(source, link)?;
        } else {
            std::os::windows::fs::symlink_file(source, link)?;
        }
    }
    Ok(())
}

fn remove_path(path: &Path) -> Result<()> {
    let metadata = path.symlink_metadata()?;
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symlinked_directory_contents_preserve_destination_as_real_directory() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(source.join("Sources")).unwrap();
        fs::write(source.join("Package.swift"), "").unwrap();
        fs::write(source.join("Sources/Library.swift"), "").unwrap();

        replace_with_symlinked_directory_contents(&source, &destination).unwrap();

        assert!(destination.is_dir());
        assert!(
            !destination
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(
            destination
                .join("Package.swift")
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(
            destination
                .join("Sources")
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            destination.join("..").canonicalize().unwrap(),
            temp.path().canonicalize().unwrap()
        );
    }
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
