use std::{fs, process::Command, time::Duration};

use anyhow::{Context, Result, anyhow};
use semver::Version;
use serde::{Deserialize, Serialize};

use crate::{
    cache::Cache,
    github::{GitHubRepo, github_token},
    util::{atomic_write, command_output, http_client},
};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct RemoteVersion {
    pub(crate) version: Version,
    pub(crate) revision: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RemoteVersionsCache {
    location: String,
    versions: Vec<RemoteVersion>,
}

pub(crate) fn remote_versions(location: &str, cache: &Cache) -> Result<Vec<RemoteVersion>> {
    if let Some(versions) = read_cached_remote_versions(cache, location)? {
        return Ok(versions);
    }

    let _lock = cache.lock("remote-versions", location)?;
    if let Some(versions) = read_cached_remote_versions(cache, location)? {
        return Ok(versions);
    }

    let versions = fetch_remote_versions(location)?;
    write_cached_remote_versions(cache, location, &versions)?;
    Ok(versions)
}

fn fetch_remote_versions(location: &str) -> Result<Vec<RemoteVersion>> {
    // `git ls-remote --tags` returns every tag with its commit SHA in a single
    // round trip. The GitHub tags API paginates (100 tags per page) and adds
    // JSON parsing overhead, so we only fall back to it when ls-remote fails
    // (e.g. SSH-only auth without git available).
    if let Ok(versions) = git_remote_versions(location) {
        if !versions.is_empty() {
            return Ok(versions);
        }
    }
    if let Ok(github) = GitHubRepo::parse(location) {
        return github_remote_versions(&github);
    }
    Ok(Vec::new())
}

fn read_cached_remote_versions(
    cache: &Cache,
    location: &str,
) -> Result<Option<Vec<RemoteVersion>>> {
    let path = cache.remote_versions_path(location);
    if !path.exists() {
        return Ok(None);
    }

    let metadata = fs::metadata(&path)?;
    let modified = metadata.modified()?;
    if modified.elapsed().unwrap_or(Duration::MAX) > Duration::from_secs(60 * 60) {
        return Ok(None);
    }

    let file = fs::File::open(&path)?;
    let cached: RemoteVersionsCache = serde_json::from_reader(file)
        .with_context(|| format!("failed to parse {}", path.display()))?;
    if cached.location != location {
        return Ok(None);
    }
    Ok(Some(cached.versions))
}

fn write_cached_remote_versions(
    cache: &Cache,
    location: &str,
    versions: &[RemoteVersion],
) -> Result<()> {
    let path = cache.remote_versions_path(location);
    let bytes = serde_json::to_vec_pretty(&RemoteVersionsCache {
        location: location.to_string(),
        versions: versions.to_vec(),
    })?;
    atomic_write(&path, &bytes)?;
    Ok(())
}

fn github_remote_versions(repo: &GitHubRepo) -> Result<Vec<RemoteVersion>> {
    #[derive(Deserialize)]
    struct Tag {
        name: String,
        commit: Commit,
    }
    #[derive(Deserialize)]
    struct Commit {
        sha: String,
    }

    let client = http_client();
    let mut page = 1;
    let mut versions = Vec::new();
    loop {
        let url = format!(
            "https://api.github.com/repos/{}/{}/tags?per_page=100&page={page}",
            repo.owner, repo.repo
        );
        let mut request = client.get(url);
        if let Some(token) = github_token() {
            request = request.bearer_auth(token);
        }
        let tags: Vec<Tag> = request.send()?.error_for_status()?.json()?;
        if tags.is_empty() {
            break;
        }
        for tag in tags {
            if let Some(version) = parse_swift_tag_version(&tag.name) {
                versions.push(RemoteVersion {
                    version,
                    revision: tag.commit.sha,
                });
            }
        }
        page += 1;
    }
    Ok(versions)
}

fn git_remote_versions(location: &str) -> Result<Vec<RemoteVersion>> {
    let output = command_output(Command::new("git").args(["ls-remote", "--tags", location]))
        .with_context(|| format!("failed to list remote tags for {location}"))?;
    let mut peeled = std::collections::BTreeMap::<String, String>::new();
    let mut direct = std::collections::BTreeMap::<String, String>::new();
    for line in output.lines() {
        let mut parts = line.split_whitespace();
        let Some(sha) = parts.next() else { continue };
        let Some(ref_name) = parts.next() else {
            continue;
        };
        let Some(tag) = ref_name.strip_prefix("refs/tags/") else {
            continue;
        };
        if let Some(tag) = tag.strip_suffix("^{}") {
            peeled.insert(tag.to_string(), sha.to_string());
        } else {
            direct.insert(tag.to_string(), sha.to_string());
        }
    }

    let mut versions = Vec::new();
    for (tag, sha) in direct {
        if let Some(version) = parse_swift_tag_version(&tag) {
            let revision = peeled.get(&tag).cloned().unwrap_or(sha);
            versions.push(RemoteVersion { version, revision });
        }
    }
    Ok(versions)
}

pub(crate) fn resolve_named_ref(location: &str, name: &str) -> Result<String> {
    let output = command_output(Command::new("git").args(["ls-remote", location, name]))
        .with_context(|| format!("failed to resolve {name} in {location}"))?;
    let line = output
        .lines()
        .next()
        .ok_or_else(|| anyhow!("{name} was not found in {location}"))?;
    let revision = line
        .split_whitespace()
        .next()
        .ok_or_else(|| anyhow!("ls-remote returned an invalid line"))?;
    Ok(revision.to_string())
}

pub(crate) fn parse_swift_tag_version(tag: &str) -> Option<Version> {
    let tag = tag.trim_start_matches('v');
    Version::parse(tag).ok()
}
