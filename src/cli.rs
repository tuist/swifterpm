use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};

use crate::{
    cache::Cache,
    package_info_cache::write_package_info_cache,
    resolve::resolve_package,
    resolved::{print_resolution, read_resolved_file, write_resolved_file},
    restore::restore_package,
};

#[derive(Debug, Parser)]
#[command(
    version,
    about = "A fast Rust prototype for Swift package resolution and checkout restoration"
)]
struct Cli {
    /// Change the working directory before resolving the package.
    #[arg(long, global = true)]
    chdir: Option<PathBuf>,
    /// Specify the package root directory.
    #[arg(long, global = true, value_name = "package-path")]
    package_path: Option<PathBuf>,
    /// Specify the shared cache directory used by swifterpm.
    #[arg(long, global = true, value_name = "cache-path")]
    cache_path: Option<PathBuf>,
    /// Specify the SwiftPM scratch directory. Defaults to <package>/.build.
    #[arg(long, global = true, value_name = "scratch-path")]
    scratch_path: Option<PathBuf>,
    /// Accept SwiftPM's build-path flag and use it as the checkout scratch root when scratch-path is absent.
    #[arg(long, global = true, value_name = "build-path")]
    build_path: Option<PathBuf>,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true, value_name = "config-path")]
    config_path: Option<PathBuf>,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true, value_name = "security-path")]
    security_path: Option<PathBuf>,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true)]
    disable_sandbox: bool,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true)]
    enable_dependency_cache: bool,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true)]
    disable_dependency_cache: bool,
    /// Prefer the existing Package.resolved file instead of refreshing versions.
    #[arg(long, global = true)]
    skip_update: bool,
    /// Resolve exclusively from Package.resolved.
    #[arg(long, global = true)]
    force_resolved_versions: bool,
    /// Resolve exclusively from Package.resolved.
    #[arg(long, global = true)]
    disable_automatic_resolution: bool,
    /// Resolve exclusively from Package.resolved.
    #[arg(long, global = true)]
    only_use_versions_from_resolved_file: bool,
    /// Accepted for SwiftPM command compatibility. Registry resolution is not implemented yet.
    #[arg(long, global = true)]
    replace_scm_with_registry: bool,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true)]
    use_registry_identity_for_scm: bool,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true, value_name = "default-registry-url")]
    default_registry_url: Option<String>,
    /// Accepted for SwiftPM command compatibility.
    #[arg(long, global = true)]
    disable_scm_to_registry_transformation: bool,
    /// Suppress resolution and restore progress output.
    #[arg(short, long, global = true)]
    quiet: bool,
    /// Do not cache SwiftPM dump-package JSON for Tuist's later graph loading.
    #[arg(long, global = true)]
    disable_package_info_cache: bool,
    /// Directory where package manifest JSON should be cached. Defaults to <scratch>/swifterpm/package-info.
    #[arg(long, global = true, value_name = "package-info-cache-path")]
    package_info_cache_path: Option<PathBuf>,
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Resolve direct source-control dependencies and restore checkouts.
    Resolve {
        #[arg(value_name = "package-name")]
        package_name: Option<String>,
        /// SwiftPM-compatible package-specific pin request. Not implemented by swifterpm yet.
        #[arg(long)]
        version: Option<String>,
        /// SwiftPM-compatible package-specific branch pin request. Not implemented by swifterpm yet.
        #[arg(long)]
        branch: Option<String>,
        /// SwiftPM-compatible package-specific revision pin request. Not implemented by swifterpm yet.
        #[arg(long)]
        revision: Option<String>,
        #[arg(long, default_value = ".")]
        package_dir: PathBuf,
        #[arg(long)]
        cache_dir: Option<PathBuf>,
        /// Write Package.resolved in SwiftPM's current JSON shape. This is the default for resolve/update.
        #[arg(long)]
        write: bool,
        /// Restore checkouts after resolving. This is the default for resolve/update.
        #[arg(long)]
        restore: bool,
        /// Print the resolution without writing Package.resolved or restoring checkouts.
        #[arg(long)]
        print_only: bool,
    },
    /// Re-resolve direct source-control dependencies and restore checkouts.
    Update {
        #[arg(value_name = "package-name")]
        package_names: Vec<String>,
        #[arg(long, default_value = ".")]
        package_dir: PathBuf,
        #[arg(long)]
        cache_dir: Option<PathBuf>,
        #[arg(long)]
        write: bool,
        #[arg(long)]
        restore: bool,
        #[arg(long)]
        print_only: bool,
    },
    /// Restore source-control pins from Package.resolved into checkouts using global symlinks.
    Restore {
        #[arg(long, default_value = ".")]
        package_dir: PathBuf,
        #[arg(long)]
        cache_dir: Option<PathBuf>,
        #[arg(long)]
        scratch_dir: Option<PathBuf>,
    },
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();
    if let Some(chdir) = &cli.chdir {
        std::env::set_current_dir(chdir)
            .with_context(|| format!("failed to chdir to {}", chdir.display()))?;
    }

    match &cli.command {
        Commands::Resolve {
            package_name,
            version,
            branch,
            revision,
            package_dir,
            cache_dir,
            write,
            restore,
            print_only,
        } => {
            ensure_whole_package_resolution(package_name.as_deref(), version, branch, revision)?;
            run_resolution_command(
                &cli,
                package_dir,
                cache_dir.as_ref(),
                *write,
                *restore,
                *print_only,
            )
        }
        Commands::Update {
            package_names,
            package_dir,
            cache_dir,
            write,
            restore,
            print_only,
        } => {
            if !package_names.is_empty() {
                bail!("package-specific update is not supported yet");
            }
            run_resolution_command(
                &cli,
                package_dir,
                cache_dir.as_ref(),
                *write,
                *restore,
                *print_only,
            )
        }
        Commands::Restore {
            package_dir,
            cache_dir,
            scratch_dir,
        } => {
            let cache = Cache::new(cli_cache_dir(&cli, cache_dir.as_ref()))?;
            let package = canonical_package_dir(command_package_dir(&cli, package_dir))?;
            let scratch = command_scratch_dir(&cli, &package, scratch_dir.as_ref());
            let resolved = read_resolved_file(&package)?;
            restore_package(&scratch, &cache, &resolved, cli.quiet)?;
            maybe_write_package_info_cache(&cli, &package, &scratch, &resolved)
        }
    }
}

fn run_resolution_command(
    cli: &Cli,
    package_dir: &PathBuf,
    cache_dir: Option<&PathBuf>,
    write: bool,
    restore: bool,
    print_only: bool,
) -> Result<()> {
    let cache = Cache::new(cli_cache_dir(cli, cache_dir))?;
    let package = canonical_package_dir(command_package_dir(cli, package_dir))?;
    let scratch = command_scratch_dir(cli, &package, None);
    let read_only = cli.force_resolved_versions
        || cli.disable_automatic_resolution
        || cli.only_use_versions_from_resolved_file;

    let resolved = if read_only || (cli.skip_update && package.join("Package.resolved").exists()) {
        read_resolved_file(&package)
            .with_context(|| format!("failed to read Package.resolved for {}", package.display()))?
    } else {
        let resolved = resolve_package(&package, &cache, cli.disable_sandbox)?;
        if should_write(write, print_only) {
            write_resolved_file(&package, &resolved)?;
        }
        resolved
    };

    if !cli.quiet {
        print_resolution(&resolved);
    }
    if should_restore(restore, print_only) {
        restore_package(&scratch, &cache, &resolved, cli.quiet)?;
        maybe_write_package_info_cache(cli, &package, &scratch, &resolved)?;
    }
    Ok(())
}

fn maybe_write_package_info_cache(
    cli: &Cli,
    package: &std::path::Path,
    scratch: &std::path::Path,
    resolved: &crate::resolved::ResolvedPins,
) -> Result<()> {
    if cli.disable_package_info_cache {
        return Ok(());
    }
    write_package_info_cache(
        package,
        scratch,
        resolved,
        cli.package_info_cache_path.as_deref(),
        cli.disable_sandbox,
        cli.quiet,
    )
}

fn ensure_whole_package_resolution(
    package_name: Option<&str>,
    version: &Option<String>,
    branch: &Option<String>,
    revision: &Option<String>,
) -> Result<()> {
    if package_name.is_some() || version.is_some() || branch.is_some() || revision.is_some() {
        bail!("package-specific resolve is not supported yet");
    }
    Ok(())
}

fn should_write(write: bool, print_only: bool) -> bool {
    !print_only || write
}

fn should_restore(restore: bool, print_only: bool) -> bool {
    !print_only || restore
}

fn cli_cache_dir(cli: &Cli, command_cache_dir: Option<&PathBuf>) -> Option<PathBuf> {
    command_cache_dir
        .cloned()
        .or_else(|| cli.cache_path.clone())
}

fn command_package_dir(cli: &Cli, command_package_dir: &PathBuf) -> PathBuf {
    cli.package_path
        .clone()
        .unwrap_or_else(|| command_package_dir.clone())
}

fn command_scratch_dir(
    cli: &Cli,
    package_dir: &std::path::Path,
    command_scratch_dir: Option<&PathBuf>,
) -> PathBuf {
    command_scratch_dir
        .cloned()
        .or_else(|| cli.scratch_path.clone())
        .or_else(|| cli.build_path.clone())
        .unwrap_or_else(|| package_dir.join(".build"))
}

fn canonical_package_dir(package_dir: PathBuf) -> Result<PathBuf> {
    package_dir.canonicalize().with_context(|| {
        format!(
            "failed to canonicalize package dir {}",
            package_dir.display()
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_swiftpm_shaped_resolve_invocation() {
        let cli = Cli::try_parse_from([
            "swifterpm",
            "--package-path",
            "../tuist",
            "--scratch-path",
            "/tmp/tuist-build",
            "--replace-scm-with-registry",
            "--force-resolved-versions",
            "--disable-package-info-cache",
            "resolve",
        ])
        .unwrap();

        assert_eq!(cli.package_path, Some(PathBuf::from("../tuist")));
        assert_eq!(cli.scratch_path, Some(PathBuf::from("/tmp/tuist-build")));
        assert!(cli.replace_scm_with_registry);
        assert!(cli.force_resolved_versions);
        assert!(matches!(cli.command, Commands::Resolve { .. }));
    }

    #[test]
    fn accepts_build_path_as_scratch_fallback() {
        let cli = Cli::try_parse_from([
            "swifterpm",
            "--package-path",
            ".",
            "--build-path",
            "/tmp/custom-build",
            "update",
        ])
        .unwrap();

        assert_eq!(
            command_scratch_dir(&cli, std::path::Path::new("/package"), None),
            PathBuf::from("/tmp/custom-build")
        );
        assert!(matches!(cli.command, Commands::Update { .. }));
    }
}
