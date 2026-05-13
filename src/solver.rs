use std::{cmp::Reverse, collections::BTreeMap, convert::Infallible, fmt};

use anyhow::{Result, anyhow};
use pubgrub::{
    Dependencies, DependencyConstraints, DependencyProvider, PackageResolutionStatistics, Ranges,
    resolve as pubgrub_resolve,
};
use semver::Version;

use crate::manifest::Requirement;

pub(crate) type SolverVersionRange = Ranges<Version>;

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct SolverPackage(String);

#[allow(dead_code)]
impl SolverPackage {
    fn root() -> Self {
        Self("__root__".to_string())
    }
}

impl From<&str> for SolverPackage {
    fn from(value: &str) -> Self {
        Self(value.to_string())
    }
}

impl From<String> for SolverPackage {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl fmt::Display for SolverPackage {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[allow(dead_code)]
#[derive(Debug, Default)]
pub(crate) struct PubgrubDependencyProvider {
    versions: BTreeMap<SolverPackage, Vec<Version>>,
    dependencies: BTreeMap<(SolverPackage, Version), Vec<(SolverPackage, SolverVersionRange)>>,
}

#[allow(dead_code)]
impl PubgrubDependencyProvider {
    pub(crate) fn add_versions(
        &mut self,
        package: impl Into<SolverPackage>,
        mut versions: Vec<Version>,
    ) {
        versions.sort();
        self.versions.insert(package.into(), versions);
    }

    pub(crate) fn add_dependencies(
        &mut self,
        package: impl Into<SolverPackage>,
        version: Version,
        dependencies: Vec<(SolverPackage, SolverVersionRange)>,
    ) {
        self.dependencies
            .insert((package.into(), version), dependencies);
    }
}

impl DependencyProvider for PubgrubDependencyProvider {
    type Err = Infallible;
    type M = String;
    type P = SolverPackage;
    type Priority = Reverse<usize>;
    type V = Version;
    type VS = SolverVersionRange;

    fn prioritize(
        &self,
        package: &Self::P,
        range: &Self::VS,
        _package_conflicts_counts: &PackageResolutionStatistics,
    ) -> Self::Priority {
        let compatible_versions = self
            .versions
            .get(package)
            .map(|versions| {
                versions
                    .iter()
                    .filter(|version| range.contains(version))
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
        Ok(self.versions.get(package).and_then(|versions| {
            versions
                .iter()
                .rev()
                .find(|version| range.contains(version))
                .cloned()
        }))
    }

    fn get_dependencies(
        &self,
        package: &Self::P,
        version: &Self::V,
    ) -> std::result::Result<Dependencies<Self::P, Self::VS, Self::M>, Self::Err> {
        let Some(versions) = self.versions.get(package) else {
            return Ok(Dependencies::Unavailable(format!(
                "no versions found for {package}"
            )));
        };
        if !versions.contains(version) {
            return Ok(Dependencies::Unavailable(format!(
                "{package} {version} is not available"
            )));
        }

        let dependencies = self
            .dependencies
            .get(&(package.clone(), version.clone()))
            .cloned()
            .unwrap_or_default();
        Ok(Dependencies::Available(DependencyConstraints::from_iter(
            dependencies,
        )))
    }
}

#[allow(dead_code)]
pub(crate) fn version_range_for_requirement(
    requirement: &Requirement,
) -> Option<SolverVersionRange> {
    match requirement {
        Requirement::Exact(version) => Some(Ranges::singleton(version.clone())),
        Requirement::Range { lower, upper } => Some(Ranges::between(lower.clone(), upper.clone())),
        Requirement::Revision(_) | Requirement::Branch(_) => None,
    }
}

#[allow(dead_code)]
pub(crate) fn solve_pubgrub_dependencies(
    mut provider: PubgrubDependencyProvider,
    root_dependencies: Vec<(SolverPackage, SolverVersionRange)>,
) -> Result<BTreeMap<String, Version>> {
    let root = SolverPackage::root();
    let root_version = Version::new(0, 0, 0);
    provider.add_versions(root.clone(), vec![root_version.clone()]);
    provider.add_dependencies(root.clone(), root_version.clone(), root_dependencies);

    let selected = pubgrub_resolve(&provider, root.clone(), root_version)
        .map_err(|error| anyhow!("failed to solve dependency graph: {error:?}"))?;
    Ok(selected
        .into_iter()
        .filter_map(|(package, version)| {
            if package == root {
                None
            } else {
                Some((package.0, version))
            }
        })
        .collect())
}
