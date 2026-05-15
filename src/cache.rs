use std::{env, ffi::OsString, fs, path::PathBuf};

use anyhow::{Result, anyhow};

use crate::{
    resolved::ResolvedPin,
    util::{PathLock, lock_path, short_revision, stable_hash},
};

#[derive(Debug, Clone)]
pub(crate) struct Cache {
    pub(crate) root: PathBuf,
}

impl Cache {
    pub(crate) fn new(root: Option<PathBuf>) -> Result<Self> {
        let root = match root {
            Some(root) => root,
            None => default_cache_root()?,
        };
        fs::create_dir_all(root.join("sources"))?;
        fs::create_dir_all(root.join("archives"))?;
        fs::create_dir_all(root.join("registry/archives"))?;
        fs::create_dir_all(root.join("metadata/remotes"))?;
        fs::create_dir_all(root.join("metadata/registries"))?;
        fs::create_dir_all(root.join("locks"))?;
        fs::create_dir_all(root.join("virtual/checkouts"))?;
        Ok(Self { root })
    }

    pub(crate) fn source_path(&self, pin: &ResolvedPin) -> Result<PathBuf> {
        if pin.kind == "registry" {
            return Ok(self
                .root
                .join("sources")
                .join(&pin.identity)
                .join(format!("{}-registry", pin.version()?)));
        }

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

    pub(crate) fn registry_archive_path(&self, identity: &str, version: &str) -> PathBuf {
        self.root.join("registry/archives").join(format!(
            "{}-{}.zip",
            stable_hash(identity),
            version
        ))
    }

    pub(crate) fn remote_versions_path(&self, location: &str) -> PathBuf {
        self.root
            .join("metadata/remotes")
            .join(format!("{}.json", stable_hash(location)))
    }

    pub(crate) fn registry_versions_path(&self, registry_url: &str, identity: &str) -> PathBuf {
        self.root.join("metadata/registries").join(format!(
            "{}-{}.json",
            stable_hash(registry_url),
            stable_hash(identity)
        ))
    }

    pub(crate) fn lock(&self, namespace: &str, key: &str) -> Result<PathLock> {
        lock_path(
            &self
                .root
                .join("locks")
                .join(namespace)
                .join(format!("{}.lock", stable_hash(key))),
        )
    }
}

fn default_cache_root() -> Result<PathBuf> {
    default_cache_root_from_env(env::var_os("XDG_CACHE_HOME"), env::var_os("HOME"))
}

fn default_cache_root_from_env(
    xdg_cache_home: Option<OsString>,
    home: Option<OsString>,
) -> Result<PathBuf> {
    if let Some(xdg_cache_home) = xdg_cache_home {
        let xdg_cache_home = PathBuf::from(xdg_cache_home);
        if xdg_cache_home.is_absolute() {
            return Ok(xdg_cache_home.join("swifterpm"));
        }
    }

    home.map(PathBuf::from)
        .filter(|home| home.is_absolute())
        .map(|home| home.join(".cache/swifterpm"))
        .ok_or_else(|| anyhow!("could not find user cache directory from XDG_CACHE_HOME or HOME"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resolved::{ResolvedPin, ResolvedState};

    fn source_control_pin(identity: &str, version: Option<&str>, revision: &str) -> ResolvedPin {
        ResolvedPin {
            identity: identity.to_string(),
            kind: "remoteSourceControl".to_string(),
            location: format!("https://github.com/example/{identity}"),
            state: ResolvedState {
                branch: None,
                revision: Some(revision.to_string()),
                version: version.map(str::to_string),
            },
        }
    }

    fn branch_pin(identity: &str, branch: &str, revision: &str) -> ResolvedPin {
        ResolvedPin {
            identity: identity.to_string(),
            kind: "remoteSourceControl".to_string(),
            location: format!("https://github.com/example/{identity}"),
            state: ResolvedState {
                branch: Some(branch.to_string()),
                revision: Some(revision.to_string()),
                version: None,
            },
        }
    }

    fn registry_pin(identity: &str, version: &str) -> ResolvedPin {
        ResolvedPin {
            identity: identity.to_string(),
            kind: "registry".to_string(),
            location: String::new(),
            state: ResolvedState {
                branch: None,
                revision: None,
                version: Some(version.to_string()),
            },
        }
    }

    #[test]
    fn source_path_for_versioned_pin_uses_version_and_short_revision() {
        let cache = Cache {
            root: PathBuf::from("/cache"),
        };
        let pin = source_control_pin("alamofire", Some("5.10.2"), "0123456789abcdef");

        let path = cache.source_path(&pin).unwrap();

        assert_eq!(
            path,
            PathBuf::from("/cache/sources/alamofire/5.10.2-0123456789ab")
        );
    }

    #[test]
    fn source_path_for_branch_pin_uses_branch_and_short_revision() {
        let cache = Cache {
            root: PathBuf::from("/cache"),
        };
        let pin = branch_pin("alamofire", "main", "fedcba9876543210");

        let path = cache.source_path(&pin).unwrap();

        assert_eq!(
            path,
            PathBuf::from("/cache/sources/alamofire/main-fedcba987654")
        );
    }

    #[test]
    fn source_path_for_registry_pin_uses_version_registry_suffix() {
        let cache = Cache {
            root: PathBuf::from("/cache"),
        };
        let pin = registry_pin("apple.swift-log", "1.6.4");

        let path = cache.source_path(&pin).unwrap();

        assert_eq!(
            path,
            PathBuf::from("/cache/sources/apple.swift-log/1.6.4-registry")
        );
    }

    #[test]
    fn archive_path_stably_hashes_url_and_shortens_revision() {
        let cache = Cache {
            root: PathBuf::from("/cache"),
        };

        let first = cache.archive_path("https://github.com/example/alamofire", "abcdef1234567890");
        let second = cache.archive_path("https://github.com/example/alamofire", "abcdef1234567890");
        let different =
            cache.archive_path("https://github.com/example/different", "abcdef1234567890");

        assert_eq!(first, second);
        assert_ne!(first, different);
        assert!(first.starts_with("/cache/archives"));
        assert!(
            first
                .file_name()
                .unwrap()
                .to_string_lossy()
                .ends_with("-abcdef123456.tar.gz")
        );
    }

    #[test]
    fn registry_archive_path_hashes_identity_and_keeps_full_version() {
        let cache = Cache {
            root: PathBuf::from("/cache"),
        };

        let path = cache.registry_archive_path("apple.swift-log", "1.6.4");

        assert!(path.starts_with("/cache/registry/archives"));
        assert!(
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .ends_with("-1.6.4.zip")
        );
    }

    #[test]
    fn metadata_paths_disambiguate_distinct_inputs() {
        let cache = Cache {
            root: PathBuf::from("/cache"),
        };

        let remote_a = cache.remote_versions_path("https://github.com/example/a");
        let remote_b = cache.remote_versions_path("https://github.com/example/b");
        let registry_a = cache.registry_versions_path("https://registry.example", "scope.a");
        let registry_a_other_registry =
            cache.registry_versions_path("https://other-registry.example", "scope.a");

        assert!(remote_a.starts_with("/cache/metadata/remotes"));
        assert!(registry_a.starts_with("/cache/metadata/registries"));
        assert_ne!(remote_a, remote_b);
        assert_ne!(registry_a, registry_a_other_registry);
    }

    #[test]
    fn default_cache_root_uses_xdg_cache_home() {
        let got = default_cache_root_from_env(
            Some(OsString::from(test_xdg_cache_home())),
            Some(OsString::from(test_home())),
        )
        .unwrap();

        assert_eq!(got, PathBuf::from(test_xdg_cache_home()).join("swifterpm"));
    }

    #[test]
    fn default_cache_root_falls_back_to_home_cache_directory() {
        let got = default_cache_root_from_env(None, Some(OsString::from(test_home()))).unwrap();

        assert_eq!(got, PathBuf::from(test_home()).join(".cache/swifterpm"));
    }

    #[test]
    fn default_cache_root_ignores_relative_xdg_cache_home() {
        let got = default_cache_root_from_env(
            Some(OsString::from("relative")),
            Some(OsString::from(test_home())),
        )
        .unwrap();

        assert_eq!(got, PathBuf::from(test_home()).join(".cache/swifterpm"));
    }

    fn test_xdg_cache_home() -> &'static str {
        if cfg!(windows) {
            r"C:\Users\test\AppData\Local\cache"
        } else {
            "/tmp/xdg-cache"
        }
    }

    fn test_home() -> &'static str {
        if cfg!(windows) {
            r"C:\Users\test"
        } else {
            "/tmp/home"
        }
    }
}
