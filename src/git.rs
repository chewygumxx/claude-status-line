// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/git.rs
//
//

//! Subprocess-free git branch discovery.
//!
//! This deliberately does not shell out to `git`: this program runs
//! synchronously on every status-line render, and avoiding a process
//! fork/exec on that hot path is a real, measurable latency win worth
//! keeping: the original script made the same choice, and this module
//! preserves it while fixing the one place it fell short: a plain `.git`
//! *directory* walk silently stops working from a git worktree or
//! submodule, where `.git` is a *file* containing a `gitdir: <path>`
//! pointer rather than the repo metadata itself. `resolve_git_dir`
//! follows that pointer.
//!
//! [`locate`] additionally reads `config` (for the `origin` remote's URL)
//! straight off disk the same way, rather than shelling out to
//! `git config`. The one deliberate exception to this module's
//! subprocess-free approach lives in `repo_status.rs`, not here: dirty-file
//! counts and ahead/behind checks have no reasonable non-subprocess
//! implementation.

use std::path::{Path, PathBuf};

/// Discovers the current git branch (or a short detached-HEAD hash) by
/// walking up from `start` looking for a `.git` entry.
pub fn current_branch(start: &Path) -> Option<String> {
    let (_, git_dir) = find_git_dir(start)?;
    read_head(&git_dir.join("HEAD"))
}

/// Everything the status line's `WHERE` row needs about the git repository
/// containing `start`, or `None` if `start` isn't inside one.
pub struct RepoInfo {
    /// Absolute path to the repository's worktree root (the directory
    /// containing `.git`).
    pub root: PathBuf,
    /// Current branch, or a short detached-HEAD hash; `None` for an
    /// unresolvable `HEAD` (e.g. an unborn branch in a fresh repo).
    pub branch: Option<String>,
    /// The `origin` remote's owner/org, parsed from its URL. `None` if
    /// there's no origin remote or its URL doesn't parse.
    pub owner: Option<String>,
    /// The `origin` remote's repository name, parsed from its URL. `None`
    /// under the same conditions as `owner`.
    pub repo: Option<String>,
}

/// Locates the git repository containing `start`, if any, gathering its
/// root, branch, and `origin` remote owner/repo in a single directory walk.
pub fn locate(start: &Path) -> Option<RepoInfo> {
    let (root, git_dir) = find_git_dir(start)?;
    let branch = read_head(&git_dir.join("HEAD"));
    let (owner, repo) = std::fs::read_to_string(git_dir.join("config"))
        .ok()
        .as_deref()
        .and_then(origin_url)
        .and_then(|url| parse_owner_repo(&url))
        .map_or((None, None), |(o, r)| (Some(o), Some(r)));
    Some(RepoInfo {
        root,
        branch,
        owner,
        repo,
    })
}

/// Walks up from `start` looking for a `.git` entry, returning the
/// repository root (the directory containing it) and the resolved git
/// directory that actually holds `HEAD`/`config` (following worktree or
/// submodule `gitdir:` pointers via [`resolve_git_dir`]).
fn find_git_dir(start: &Path) -> Option<(PathBuf, PathBuf)> {
    let mut dir = to_absolute(start);

    loop {
        if let Some(git_dir) = resolve_git_dir(&dir.join(".git")) {
            return Some((dir, git_dir));
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// Scans a `.git/config` file's contents for the `[remote "origin"]`
/// section's `url` value, parsing it directly rather than shelling out to
/// `git config`, matching this module's general no-subprocess approach.
fn origin_url(config: &str) -> Option<String> {
    let mut in_origin_section = false;
    for raw_line in config.lines() {
        let line = raw_line.trim();
        if let Some(section) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            in_origin_section = section == "remote \"origin\"";
            continue;
        }
        if !in_origin_section {
            continue;
        }
        if let Some(rest) = line.strip_prefix("url")
            && let Some(value) = rest.trim_start().strip_prefix('=')
        {
            return Some(value.trim().to_string());
        }
    }
    None
}

/// Extracts `(owner, repo)` from a git remote URL, handling scp-like
/// (`git@github.com:owner/repo.git`), `https://`, and `ssh://` forms, with
/// or without a trailing `.git` suffix.
fn parse_owner_repo(url: &str) -> Option<(String, String)> {
    let url = url.trim();
    let without_scheme = url.split_once("://").map_or(url, |(_, rest)| rest);
    let without_user = without_scheme
        .split_once('@')
        .map_or(without_scheme, |(_, rest)| rest);
    let idx = without_user.find(['/', ':'])?;
    let path = &without_user[idx + 1..];
    let path = path.strip_suffix(".git").unwrap_or(path);
    let path = path.trim_matches('/');

    let (owner, repo) = path.rsplit_once('/')?;
    if repo.is_empty() || owner.is_empty() {
        return None;
    }
    Some((owner.to_string(), repo.to_string()))
}

/// Makes `path` absolute without touching the filesystem, with no existence
/// check and no symlink resolution, matching the original script's
/// `os.path.abspath`. Deliberately *not* [`Path::canonicalize`]: that
/// requires the path to exist, and on failure it would be tempting to fall
/// back to the process's own current directory, which would silently walk
/// up from the wrong place entirely for any `start` that doesn't (yet, or
/// ever) exist on disk rather than just treating it as already absolute.
pub(crate) fn to_absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    }
}

/// Given a candidate `.git` path (directory in an ordinary repo, file in a
/// worktree or submodule), returns the actual git directory that holds
/// `HEAD`/`config` (following the worktree/submodule `gitdir:` pointer file
/// when `git_path` isn't already a directory).
fn resolve_git_dir(git_path: &Path) -> Option<PathBuf> {
    if git_path.is_dir() {
        return Some(git_path.to_path_buf());
    }
    if git_path.is_file() {
        let contents = std::fs::read_to_string(git_path).ok()?;
        let target = contents.trim().strip_prefix("gitdir:")?.trim();
        let mut gitdir = PathBuf::from(target);
        if gitdir.is_relative() {
            gitdir = git_path.parent()?.join(gitdir);
        }
        return Some(gitdir);
    }
    None
}

/// Reads a `HEAD` file and extracts a branch name or short commit hash.
///
/// Returns `None` (rather than `Some(String::new())`) for an empty or
/// whitespace-only `HEAD` file, matching the original script's `if branch:`
/// check, which treated an empty string the same as no branch at all. A
/// caller that skipped this and pushed `Some("")` straight through would
/// render a dangling separator with nothing after it.
fn read_head(head: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(head).ok()?;
    let line = contents.trim();
    let result = match line.strip_prefix("ref: refs/heads/") {
        Some(branch) => branch.to_string(),
        None => line.chars().take(7).collect(),
    };
    if result.is_empty() {
        None
    } else {
        Some(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn tempdir() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "claude-status-line-git-test-{}-{n}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn finds_branch_from_plain_repo() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();

        let nested = root.join("a/b/c");
        fs::create_dir_all(&nested).unwrap();

        assert_eq!(current_branch(&nested), Some("main".to_string()));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn finds_branch_from_worktree_pointer() {
        let root = tempdir();
        let real_gitdir = root.join("real-gitdir");
        fs::create_dir_all(&real_gitdir).unwrap();
        fs::write(real_gitdir.join("HEAD"), "ref: refs/heads/feature\n").unwrap();

        let worktree = root.join("worktree");
        fs::create_dir_all(&worktree).unwrap();
        fs::write(
            worktree.join(".git"),
            format!("gitdir: {}\n", real_gitdir.display()),
        )
        .unwrap();

        assert_eq!(current_branch(&worktree), Some("feature".to_string()));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn detached_head_returns_short_hash() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "abcdef0123456789\n").unwrap();

        assert_eq!(current_branch(&root), Some("abcdef0".to_string()));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn no_repo_returns_none() {
        let root = tempdir();
        assert_eq!(current_branch(&root), None);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn empty_head_file_returns_none_not_empty_string() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "").unwrap();

        assert_eq!(current_branch(&root), None);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn whitespace_only_head_file_returns_none() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "   \n").unwrap();

        assert_eq!(current_branch(&root), None);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn nonexistent_absolute_path_does_not_fall_back_to_process_cwd() {
        // This crate's own directory is a git repo; if a nonexistent `start`
        // silently fell back to `std::env::current_dir()` (this repo), this
        // would incorrectly report a branch instead of `None`.
        let nonexistent = std::env::temp_dir().join("claude-status-line-does-not-exist-12345");
        assert!(!nonexistent.exists());
        assert_eq!(current_branch(&nonexistent), None);
    }

    #[test]
    fn locate_reports_root_branch_and_scp_like_origin() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::write(
            git_dir.join("config"),
            "[core]\n\trepositoryformatversion = 0\n\
             [remote \"origin\"]\n\turl = git@github.com:chewygumxx/claude-status-line.git\n\
             \tfetch = +refs/heads/*:refs/remotes/origin/*\n",
        )
        .unwrap();

        let info = locate(&root).expect("expected a located repo");
        assert_eq!(info.root, root);
        assert_eq!(info.branch, Some("main".to_string()));
        assert_eq!(info.owner, Some("chewygumxx".to_string()));
        assert_eq!(info.repo, Some("claude-status-line".to_string()));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn locate_parses_https_and_ssh_origin_urls() {
        assert_eq!(
            parse_owner_repo("https://github.com/chewygumxx/claude-status-line.git"),
            Some(("chewygumxx".to_string(), "claude-status-line".to_string()))
        );
        assert_eq!(
            parse_owner_repo("https://github.com/chewygumxx/claude-status-line"),
            Some(("chewygumxx".to_string(), "claude-status-line".to_string()))
        );
        assert_eq!(
            parse_owner_repo("ssh://git@github.com/chewygumxx/claude-status-line.git"),
            Some(("chewygumxx".to_string(), "claude-status-line".to_string()))
        );
    }

    #[test]
    fn locate_without_origin_remote_leaves_owner_and_repo_none() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::write(
            git_dir.join("config"),
            "[core]\n\trepositoryformatversion = 0\n",
        )
        .unwrap();

        let info = locate(&root).expect("expected a located repo");
        assert_eq!(info.owner, None);
        assert_eq!(info.repo, None);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn locate_without_config_file_leaves_owner_and_repo_none() {
        let root = tempdir();
        let git_dir = root.join(".git");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("HEAD"), "ref: refs/heads/main\n").unwrap();

        let info = locate(&root).expect("expected a located repo");
        assert_eq!(info.owner, None);
        assert_eq!(info.repo, None);
        fs::remove_dir_all(&root).ok();
    }
}
