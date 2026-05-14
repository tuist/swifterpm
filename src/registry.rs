use std::{
    collections::BTreeMap,
    env, fs,
    io::{Cursor, Write},
    path::{Path, PathBuf},
    time::Duration,
};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use anyhow::{Context, Result, anyhow, bail};
use reqwest::{Url, blocking::Client, header};
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    cache::Cache,
    resolved::registry_identity_parts,
    util::{atomic_write, flatten_single_directory, http_client},
};

const ACCEPT_JSON: &str = "application/vnd.swift.registry.v1+json";
const ACCEPT_ZIP: &str = "application/vnd.swift.registry.v1+zip";

#[derive(Debug, Clone)]
pub(crate) struct RegistryConfig {
    default_registry_url: Option<Url>,
    scoped_registry_urls: BTreeMap<String, Url>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct RegistryVersion {
    pub(crate) version: Version,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RegistryVersionsCache {
    registry_url: String,
    identity: String,
    versions: Vec<RegistryVersion>,
}

#[derive(Debug, Deserialize)]
struct RegistriesFile {
    registries: Option<BTreeMap<String, RegistryEntry>>,
}

#[derive(Debug, Deserialize)]
struct RegistryEntry {
    url: String,
}

#[derive(Debug, Deserialize)]
struct ReleasesResponse {
    releases: BTreeMap<String, Release>,
}

#[derive(Debug, Deserialize)]
struct Release {
    problem: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct ReleaseInfo {
    resources: Vec<ReleaseResource>,
}

#[derive(Debug, Deserialize)]
struct ReleaseResource {
    name: String,
    #[serde(rename = "type")]
    content_type: String,
    checksum: String,
}

impl RegistryConfig {
    pub(crate) fn load(
        package_dir: &Path,
        config_path: Option<&Path>,
        default_registry_url: Option<&str>,
    ) -> Result<Self> {
        let mut config = Self {
            default_registry_url: None,
            scoped_registry_urls: BTreeMap::new(),
        };

        if let Some(global_path) = global_registries_path() {
            config.merge_file(&global_path)?;
        }

        config.merge_file(&package_dir.join(".swiftpm/configuration/registries.json"))?;

        if let Some(config_path) = config_path {
            config.merge_file(&registries_path_from_config_path(config_path))?;
        }

        if let Some(default_registry_url) = default_registry_url {
            config.default_registry_url = Some(parse_registry_url(default_registry_url)?);
        }

        Ok(config)
    }

    pub(crate) fn registry_url_for_identity(&self, identity: &str) -> Result<Url> {
        let (scope, _) = registry_identity_parts(identity)?;
        self.scoped_registry_urls
            .get(scope)
            .or(self.scoped_registry_urls.get(&scope.to_ascii_lowercase()))
            .or(self.default_registry_url.as_ref())
            .cloned()
            .ok_or_else(|| anyhow!("no registry configured for '{scope}' scope"))
    }

    fn merge_file(&mut self, path: &Path) -> Result<()> {
        if !path.exists() {
            return Ok(());
        }

        let file = fs::File::open(path)
            .with_context(|| format!("failed to open registry configuration {}", path.display()))?;
        let registries_file: RegistriesFile = serde_json::from_reader(file).with_context(|| {
            format!("failed to parse registry configuration {}", path.display())
        })?;
        let Some(registries) = registries_file.registries else {
            return Ok(());
        };

        for (scope, entry) in registries {
            let url = parse_registry_url(&entry.url)?;
            if scope == "[default]" {
                self.default_registry_url = Some(url);
            } else {
                self.scoped_registry_urls
                    .insert(scope.to_ascii_lowercase(), url);
            }
        }
        Ok(())
    }
}

pub(crate) fn registry_versions(
    identity: &str,
    registry_config: &RegistryConfig,
    cache: &Cache,
) -> Result<Vec<RegistryVersion>> {
    let registry_url = registry_config.registry_url_for_identity(identity)?;
    if let Some(versions) = read_cached_registry_versions(cache, registry_url.as_str(), identity)? {
        return Ok(versions);
    }

    let lock_key = format!("{registry_url}:{identity}");
    let _lock = cache.lock("registry-versions", &lock_key)?;
    if let Some(versions) = read_cached_registry_versions(cache, registry_url.as_str(), identity)? {
        return Ok(versions);
    }

    let versions = fetch_registry_versions(&registry_url, identity)?;
    write_cached_registry_versions(cache, registry_url.as_str(), identity, &versions)?;
    Ok(versions)
}

pub(crate) fn download_registry_archive(
    cache: &Cache,
    registry_config: &RegistryConfig,
    identity: &str,
    version: &str,
    destination: &Path,
) -> Result<()> {
    let registry_url = registry_config.registry_url_for_identity(identity)?;
    let archive_path = cache.registry_archive_path(identity, version);

    if !archive_path.exists() {
        let _lock = cache.lock("registry-archives", &archive_path.to_string_lossy())?;
        if !archive_path.exists() {
            let expected_checksum =
                fetch_source_archive_checksum(&registry_url, identity, version)?;
            let bytes = fetch_registry_archive(&registry_url, identity, version)?;
            verify_checksum(identity, version, &bytes, &expected_checksum)?;
            atomic_write(&archive_path, &bytes)?;
        }
    }

    let bytes = fs::read(&archive_path)?;
    extract_zip_archive(&bytes, destination)?;
    flatten_single_directory(destination)?;
    Ok(())
}

fn fetch_registry_versions(registry_url: &Url, identity: &str) -> Result<Vec<RegistryVersion>> {
    let response: ReleasesResponse = registry_client()
        .get(package_url(registry_url, identity, None)?)
        .header(header::ACCEPT, ACCEPT_JSON)
        .send()?
        .error_for_status()?
        .json()?;

    let mut versions = response
        .releases
        .into_iter()
        .filter(|(_, release)| release.problem.is_none())
        .filter_map(|(version, _)| Version::parse(&version).ok())
        .map(|version| RegistryVersion { version })
        .collect::<Vec<_>>();
    versions.sort_by(|left, right| left.version.cmp(&right.version));
    Ok(versions)
}

fn fetch_source_archive_checksum(
    registry_url: &Url,
    identity: &str,
    version: &str,
) -> Result<String> {
    let response: ReleaseInfo = registry_client()
        .get(package_url(registry_url, identity, Some(version))?)
        .header(header::ACCEPT, ACCEPT_JSON)
        .send()?
        .error_for_status()?
        .json()?;

    response
        .resources
        .into_iter()
        .find(|resource| {
            resource.name == "source-archive" && resource.content_type == "application/zip"
        })
        .map(|resource| resource.checksum)
        .ok_or_else(|| anyhow!("{identity} {version} does not declare a source archive checksum"))
}

fn fetch_registry_archive(registry_url: &Url, identity: &str, version: &str) -> Result<Vec<u8>> {
    let mut url = package_url(registry_url, identity, None)?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| anyhow!("registry URL cannot be a base: {registry_url}"))?;
        segments.push(&format!("{version}.zip"));
    }
    Ok(registry_client()
        .get(url)
        .header(header::ACCEPT, ACCEPT_ZIP)
        .send()?
        .error_for_status()?
        .bytes()?
        .to_vec())
}

fn verify_checksum(identity: &str, version: &str, bytes: &[u8], expected: &str) -> Result<()> {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let actual = hex::encode(hasher.finalize());
    if !actual.eq_ignore_ascii_case(expected) {
        bail!("{identity} {version} checksum mismatch: expected {expected}, got {actual}");
    }
    Ok(())
}

fn extract_zip_archive(bytes: &[u8], destination: &Path) -> Result<()> {
    let reader = Cursor::new(bytes);
    let mut archive = zip::ZipArchive::new(reader)?;
    for index in 0..archive.len() {
        let mut file = archive.by_index(index)?;
        let Some(enclosed_name) = file.enclosed_name() else {
            bail!("registry archive contains an unsafe path: {}", file.name());
        };
        let path = destination.join(enclosed_name);
        if file.is_dir() {
            fs::create_dir_all(path)?;
        } else {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut output = fs::File::create(&path)?;
            std::io::copy(&mut file, &mut output)?;
            output.flush()?;
            #[cfg(unix)]
            if let Some(mode) = file.unix_mode() {
                fs::set_permissions(&path, fs::Permissions::from_mode(mode))?;
            }
        }
    }
    Ok(())
}

fn read_cached_registry_versions(
    cache: &Cache,
    registry_url: &str,
    identity: &str,
) -> Result<Option<Vec<RegistryVersion>>> {
    let path = cache.registry_versions_path(registry_url, identity);
    if !path.exists() {
        return Ok(None);
    }

    let metadata = fs::metadata(&path)?;
    let modified = metadata.modified()?;
    if modified.elapsed().unwrap_or(Duration::MAX) > Duration::from_secs(60 * 60) {
        return Ok(None);
    }

    let file = fs::File::open(&path)?;
    let cached: RegistryVersionsCache = serde_json::from_reader(file)
        .with_context(|| format!("failed to parse {}", path.display()))?;
    if cached.registry_url != registry_url || cached.identity != identity {
        return Ok(None);
    }
    Ok(Some(cached.versions))
}

fn write_cached_registry_versions(
    cache: &Cache,
    registry_url: &str,
    identity: &str,
    versions: &[RegistryVersion],
) -> Result<()> {
    let path = cache.registry_versions_path(registry_url, identity);
    let bytes = serde_json::to_vec_pretty(&RegistryVersionsCache {
        registry_url: registry_url.to_string(),
        identity: identity.to_string(),
        versions: versions.to_vec(),
    })?;
    atomic_write(&path, &bytes)?;
    Ok(())
}

fn package_url(registry_url: &Url, identity: &str, version: Option<&str>) -> Result<Url> {
    let (scope, name) = registry_identity_parts(identity)?;
    let mut url = registry_url.clone();
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| anyhow!("registry URL cannot be a base: {registry_url}"))?;
        segments.pop_if_empty();
        segments.push(scope);
        segments.push(name);
        if let Some(version) = version {
            segments.push(version);
        }
    }
    Ok(url)
}

fn registry_client() -> &'static Client {
    http_client()
}

fn parse_registry_url(url: &str) -> Result<Url> {
    let url = Url::parse(url)?;
    if url.scheme() != "https" {
        bail!("registry URL must use https: {url}");
    }
    Ok(url)
}

fn registries_path_from_config_path(config_path: &Path) -> PathBuf {
    if config_path.is_file() {
        config_path.to_path_buf()
    } else {
        config_path.join("registries.json")
    }
}

fn global_registries_path() -> Option<PathBuf> {
    env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".swiftpm")
            .join("configuration")
            .join("registries.json")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_default_and_scoped_registries_from_swiftpm_config() {
        let temp = tempfile::tempdir().unwrap();
        let config_dir = temp.path().join(".swiftpm/configuration");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(
            config_dir.join("registries.json"),
            r#"{
                "registries": {
                    "[default]": { "url": "https://registry.example.com/swift" },
                    "tuist": { "url": "https://registry.tuist.dev/api/registry/swift" }
                },
                "version": 1
            }"#,
        )
        .unwrap();

        let config = RegistryConfig::load(temp.path(), None, None).unwrap();

        assert_eq!(
            config
                .registry_url_for_identity("apple.swift-log")
                .unwrap()
                .as_str(),
            "https://registry.example.com/swift"
        );
        assert_eq!(
            config
                .registry_url_for_identity("tuist.FileSystem")
                .unwrap()
                .as_str(),
            "https://registry.tuist.dev/api/registry/swift"
        );
    }

    #[test]
    fn builds_package_urls_with_escaped_identity_parts() {
        let url = package_url(
            &Url::parse("https://registry.tuist.dev/api/registry/swift").unwrap(),
            "apple.swift-log",
            Some("1.12.0"),
        )
        .unwrap();

        assert_eq!(
            url.as_str(),
            "https://registry.tuist.dev/api/registry/swift/apple/swift-log/1.12.0"
        );
    }
}
