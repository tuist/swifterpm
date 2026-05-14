use std::{
    cmp::Reverse,
    collections::{BTreeMap, BTreeSet},
    error::Error,
    fmt, fs,
    path::Path,
    sync::Mutex,
};

use anyhow::{Result, anyhow, bail};
use pubgrub::{
    Dependencies, DependencyConstraints, DependencyProvider, PackageResolutionStatistics, Ranges,
    resolve as pubgrub_resolve,
};
use semver::Version;
use sha2::{Digest, Sha256};

use crate::{
    cache::Cache,
    github::GitHubRepo,
    manifest::{
        ManifestDependencyKind, Requirement, dump_package, parse_manifest_dependencies,
        parse_required_manifest_dependencies,
    },
    registry::{RegistryConfig, registry_versions},
    remote::{remote_versions, resolve_named_ref},
    resolved::{ResolvedPin, ResolvedPins, ResolvedState},
    restore::{ensure_registry_source, ensure_source},
    solver::version_range_for_requirement,
};

pub(crate) fn resolve_package(
    package_dir: &Path,
    cache: &Cache,
    registry_config: &RegistryConfig,
    disable_sandbox: bool,
) -> Result<ResolvedPins> {
    let manifest = dump_package(package_dir, disable_sandbox)?;
    let dependencies = parse_manifest_dependencies(&manifest)?;
    if dependencies.is_empty() {
        bail!("no sourceControl or registry dependencies found in Package.swift");
    }

    let mut fixed_pins = Vec::new();
    let mut root_dependencies = Vec::new();
    let mut root_direct_packages = BTreeSet::new();
    for dependency in dependencies {
        if let Some(range) = version_range_for_requirement(&dependency.requirement) {
            let package = PackageKey::from_dependency(&dependency);
            root_direct_packages.insert(package.clone());
            root_dependencies.push((package, range));
        } else {
            let pin = resolve_unversioned_dependency(&dependency)
                .map_err(|error| anyhow!("failed to resolve {}: {error}", dependency.identity))?;
            fixed_pins.push(pin);
        }
    }

    let provider = NativeDependencyProvider::new(
        cache,
        registry_config,
        disable_sandbox,
        root_direct_packages,
    );
    let mut pins = provider.solve(root_dependencies)?;
    pins.extend(fixed_pins);
    pins.sort_by(|left, right| left.identity.cmp(&right.identity));

    Ok(ResolvedPins {
        origin_hash: Some(origin_hash(package_dir)?),
        pins,
        version: 3,
    })
}

fn resolve_unversioned_dependency(
    dependency: &crate::manifest::ManifestDependency,
) -> Result<ResolvedPin> {
    if dependency.kind == ManifestDependencyKind::Registry {
        bail!("registry dependencies do not support branch or revision requirements");
    }

    let state = match &dependency.requirement {
        Requirement::Revision(revision) => ResolvedState {
            branch: None,
            revision: Some(revision.clone()),
            version: None,
        },
        Requirement::Branch(branch) => {
            let revision = resolve_named_ref(&dependency.location, branch)?;
            ResolvedState {
                branch: Some(branch.clone()),
                revision: Some(revision),
                version: None,
            }
        }
        Requirement::Exact(_) | Requirement::Range { .. } => unreachable!(),
    };

    Ok(ResolvedPin {
        identity: dependency.identity.clone(),
        kind: "remoteSourceControl".to_string(),
        location: dependency.location.clone(),
        state,
    })
}

fn resolved_state_for_version(version: Version, revision: String) -> ResolvedState {
    ResolvedState {
        branch: None,
        revision: Some(revision),
        version: Some(version.to_string()),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum PackageKey {
    Root,
    Package {
        identity: String,
        kind: ManifestDependencyKind,
        location: String,
    },
}

impl PackageKey {
    fn from_dependency(dependency: &crate::manifest::ManifestDependency) -> Self {
        let location = if dependency.kind == ManifestDependencyKind::SourceControl {
            canonical_source_control_location(&dependency.location)
        } else {
            dependency.location.clone()
        };
        Self::Package {
            identity: dependency.identity.clone(),
            kind: dependency.kind.clone(),
            location,
        }
    }

    fn identity(&self) -> &str {
        match self {
            Self::Root => "__root__",
            Self::Package { identity, .. } => identity,
        }
    }
}

fn canonical_source_control_location(location: &str) -> String {
    let location = location.trim_end_matches('/').trim_end_matches(".git");
    if let Ok(repo) = GitHubRepo::parse(location) {
        return format!(
            "https://github.com/{}/{}",
            repo.owner.to_ascii_lowercase(),
            repo.repo.to_ascii_lowercase()
        );
    }
    location.to_string()
}

impl fmt::Display for PackageKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.identity())
    }
}

#[derive(Debug, Clone)]
struct ResolvedVersion {
    version: Version,
    revision: Option<String>,
}

struct NativeDependencyProvider<'a> {
    cache: &'a Cache,
    registry_config: &'a RegistryConfig,
    disable_sandbox: bool,
    root_direct_packages: BTreeSet<PackageKey>,
    versions: Mutex<BTreeMap<PackageKey, Vec<ResolvedVersion>>>,
    dependencies: Mutex<BTreeMap<(PackageKey, Version), Vec<(PackageKey, Ranges<Version>)>>>,
    fixed_pins: Mutex<BTreeMap<String, ResolvedPin>>,
}

impl<'a> NativeDependencyProvider<'a> {
    fn new(
        cache: &'a Cache,
        registry_config: &'a RegistryConfig,
        disable_sandbox: bool,
        root_direct_packages: BTreeSet<PackageKey>,
    ) -> Self {
        Self {
            cache,
            registry_config,
            disable_sandbox,
            root_direct_packages,
            versions: Mutex::new(BTreeMap::new()),
            dependencies: Mutex::new(BTreeMap::new()),
            fixed_pins: Mutex::new(BTreeMap::new()),
        }
    }

    fn solve(
        &self,
        root_dependencies: Vec<(PackageKey, Ranges<Version>)>,
    ) -> Result<Vec<ResolvedPin>> {
        let root_version = Version::new(0, 0, 0);
        self.versions.lock().unwrap().insert(
            PackageKey::Root,
            vec![ResolvedVersion {
                version: root_version.clone(),
                revision: None,
            }],
        );
        self.dependencies.lock().unwrap().insert(
            (PackageKey::Root, root_version.clone()),
            root_dependencies.clone(),
        );

        self.prewarm(root_dependencies);

        let selected = pubgrub_resolve(self, PackageKey::Root, root_version)
            .map_err(|error| anyhow!("failed to solve dependency graph: {error:?}"))?;

        let mut pins = selected
            .into_iter()
            .filter_map(|(package, version)| {
                if package == PackageKey::Root {
                    None
                } else {
                    Some(self.pin_for_version(package, version))
                }
            })
            .collect::<Result<Vec<_>>>()?;
        pins.extend(self.fixed_pins.lock().unwrap().values().cloned());
        Ok(pins)
    }

    fn prewarm(&self, root_dependencies: Vec<(PackageKey, Ranges<Version>)>) {
        // Streaming dispatch: each package gets a rayon task that fetches its
        // versions, materializes the candidate, and dumps its manifest. As soon
        // as transitives are discovered, they get their own tasks — there is no
        // wave barrier, so a fast-finishing parent does not have to wait for
        // its slower siblings before spawning its children.
        let visited: Mutex<BTreeSet<PackageKey>> = Mutex::new(BTreeSet::new());
        rayon::scope(|scope| {
            for dep in root_dependencies {
                self.spawn_prewarm(scope, dep, &visited);
            }
        });
    }

    fn spawn_prewarm<'scope>(
        &'scope self,
        scope: &rayon::Scope<'scope>,
        (package, range): (PackageKey, Ranges<Version>),
        visited: &'scope Mutex<BTreeSet<PackageKey>>,
    ) {
        if !visited.lock().unwrap().insert(package.clone()) {
            return;
        }
        scope.spawn(move |scope| {
            let Ok(versions) = self.resolved_versions(&package) else {
                return;
            };
            let mut matching = versions
                .into_iter()
                .rev()
                .filter(|version| range.contains(&version.version))
                .peekable();
            let Some(chosen) = matching
                .clone()
                .find(|version| version.version.pre.is_empty())
                .or_else(|| matching.next())
            else {
                return;
            };
            let Ok(transitives) = self.dependencies_for(&package, &chosen.version) else {
                return;
            };
            for dep in transitives {
                self.spawn_prewarm(scope, dep, visited);
            }
        });
    }

    fn resolved_versions(&self, package: &PackageKey) -> Result<Vec<ResolvedVersion>> {
        if let Some(versions) = self.versions.lock().unwrap().get(package).cloned() {
            return Ok(versions);
        }

        let mut versions = match package {
            PackageKey::Root => Vec::new(),
            PackageKey::Package {
                identity,
                kind,
                location,
            } => match kind {
                ManifestDependencyKind::SourceControl => remote_versions(location, self.cache)?
                    .into_iter()
                    .map(|version| ResolvedVersion {
                        version: version.version,
                        revision: Some(version.revision),
                    })
                    .collect(),
                ManifestDependencyKind::Registry => {
                    registry_versions(identity, self.registry_config, self.cache)?
                        .into_iter()
                        .map(|version| ResolvedVersion {
                            version: version.version,
                            revision: None,
                        })
                        .collect()
                }
            },
        };
        versions.sort_by(|left, right| left.version.cmp(&right.version));

        self.versions
            .lock()
            .unwrap()
            .insert(package.clone(), versions.clone());
        Ok(versions)
    }

    fn dependencies_for(
        &self,
        package: &PackageKey,
        version: &Version,
    ) -> Result<Vec<(PackageKey, Ranges<Version>)>> {
        if let Some(dependencies) = self
            .dependencies
            .lock()
            .unwrap()
            .get(&(package.clone(), version.clone()))
            .cloned()
        {
            return Ok(dependencies);
        }

        let source = self.materialize(package, version)?;
        let manifest = dump_package(&source, self.disable_sandbox)?;
        let manifest_dependencies = if self.root_direct_packages.contains(package) {
            parse_manifest_dependencies(&manifest)?
        } else {
            parse_required_manifest_dependencies(&manifest)?
        };
        let mut dependencies = Vec::new();
        for dependency in manifest_dependencies {
            if let Some(range) = version_range_for_requirement(&dependency.requirement) {
                dependencies.push((PackageKey::from_dependency(&dependency), range));
            } else {
                let pin = resolve_unversioned_dependency(&dependency).map_err(|error| {
                    anyhow!("failed to resolve {}: {error}", dependency.identity)
                })?;
                self.fixed_pins
                    .lock()
                    .unwrap()
                    .insert(pin.identity.to_ascii_lowercase(), pin);
            }
        }

        self.dependencies
            .lock()
            .unwrap()
            .insert((package.clone(), version.clone()), dependencies.clone());
        Ok(dependencies)
    }

    fn materialize(&self, package: &PackageKey, version: &Version) -> Result<std::path::PathBuf> {
        let pin = self.pin_for_version(package.clone(), version.clone())?;
        match package {
            PackageKey::Root => unreachable!(),
            PackageKey::Package { kind, .. } => match kind {
                ManifestDependencyKind::SourceControl => ensure_source(self.cache, &pin),
                ManifestDependencyKind::Registry => {
                    ensure_registry_source(self.cache, self.registry_config, &pin)
                }
            },
        }
    }

    fn pin_for_version(&self, package: PackageKey, version: Version) -> Result<ResolvedPin> {
        let PackageKey::Package {
            identity,
            kind,
            location,
        } = package
        else {
            unreachable!();
        };
        match kind {
            ManifestDependencyKind::SourceControl => {
                let resolved_version = self
                    .resolved_versions(&PackageKey::Package {
                        identity: identity.clone(),
                        kind: ManifestDependencyKind::SourceControl,
                        location: location.clone(),
                    })?
                    .into_iter()
                    .find(|candidate| candidate.version == version)
                    .ok_or_else(|| anyhow!("version {version} was not found for {identity}"))?;
                Ok(ResolvedPin {
                    identity,
                    kind: "remoteSourceControl".to_string(),
                    location,
                    state: resolved_state_for_version(
                        version,
                        resolved_version
                            .revision
                            .ok_or_else(|| anyhow!("source-control version has no revision"))?,
                    ),
                })
            }
            ManifestDependencyKind::Registry => Ok(ResolvedPin {
                identity,
                kind: "registry".to_string(),
                location: String::new(),
                state: ResolvedState {
                    branch: None,
                    revision: None,
                    version: Some(version.to_string()),
                },
            }),
        }
    }
}

impl DependencyProvider for NativeDependencyProvider<'_> {
    type Err = NativeResolveError;
    type M = String;
    type P = PackageKey;
    type Priority = Reverse<usize>;
    type V = Version;
    type VS = Ranges<Version>;

    fn prioritize(
        &self,
        package: &Self::P,
        range: &Self::VS,
        _package_conflicts_counts: &PackageResolutionStatistics,
    ) -> Self::Priority {
        let compatible_versions = self
            .resolved_versions(package)
            .map(|versions| {
                versions
                    .iter()
                    .filter(|version| range.contains(&version.version))
                    .count()
            })
            .unwrap_or(0);
        Reverse(compatible_versions)
    }

    fn choose_version(
        &self,
        package: &Self::P,
        range: &Self::VS,
    ) -> std::result::Result<Option<Self::V>, Self::Err> {
        let matching_versions = self
            .resolved_versions(package)
            .map_err(NativeResolveError::from)?
            .into_iter()
            .rev()
            .filter(|version| range.contains(&version.version))
            .collect::<Vec<_>>();
        Ok(matching_versions
            .iter()
            .find(|version| version.version.pre.is_empty())
            .or_else(|| matching_versions.first())
            .map(|version| version.version.clone()))
    }

    fn get_dependencies(
        &self,
        package: &Self::P,
        version: &Self::V,
    ) -> std::result::Result<Dependencies<Self::P, Self::VS, Self::M>, Self::Err> {
        let versions = self
            .resolved_versions(package)
            .map_err(NativeResolveError::from)?;
        if !versions
            .iter()
            .any(|candidate| &candidate.version == version)
        {
            return Ok(Dependencies::Unavailable(format!(
                "{package} {version} is not available"
            )));
        }

        Ok(Dependencies::Available(DependencyConstraints::from_iter(
            self.dependencies_for(package, version)
                .map_err(NativeResolveError::from)?,
        )))
    }
}

#[derive(Debug, Clone)]
struct NativeResolveError(String);

impl fmt::Display for NativeResolveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for NativeResolveError {}

impl From<anyhow::Error> for NativeResolveError {
    fn from(error: anyhow::Error) -> Self {
        Self(error.to_string())
    }
}

fn origin_hash(package_dir: &Path) -> Result<String> {
    let manifest = fs::read(package_dir.join("Package.swift"))?;
    let mut hasher = Sha256::new();
    hasher.update(manifest);
    Ok(hex::encode(hasher.finalize()))
}
