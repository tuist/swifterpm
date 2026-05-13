use std::process::Command;

use anyhow::{Result, anyhow, bail};
use url::Url;

#[derive(Debug)]
pub(crate) struct GitHubRepo {
    pub(crate) owner: String,
    pub(crate) repo: String,
}

impl GitHubRepo {
    pub(crate) fn parse(location: &str) -> Result<Self> {
        let location = if location.starts_with("git@github.com:") {
            location.replacen("git@github.com:", "https://github.com/", 1)
        } else {
            location.to_string()
        };
        let url = Url::parse(&location)?;
        if url.host_str() != Some("github.com") {
            bail!("not a GitHub URL");
        }
        let mut segments = url
            .path_segments()
            .ok_or_else(|| anyhow!("GitHub URL has no path"))?;
        let owner = segments
            .next()
            .ok_or_else(|| anyhow!("GitHub URL has no owner"))?
            .to_string();
        let repo = segments
            .next()
            .ok_or_else(|| anyhow!("GitHub URL has no repo"))?
            .trim_end_matches(".git")
            .to_string();
        Ok(Self { owner, repo })
    }
}

pub(crate) fn github_token() -> Option<String> {
    if let Ok(token) = std::env::var("GITHUB_TOKEN").or_else(|_| std::env::var("GH_TOKEN")) {
        if !token.trim().is_empty() {
            return Some(token);
        }
    }

    let output = Command::new("gh").args(["auth", "token"]).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if token.is_empty() { None } else { Some(token) }
}
