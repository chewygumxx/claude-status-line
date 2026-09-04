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
//! pointer rather than the repo metadata itself. `resolve_git_head`
//! follows that pointer.

use std::path::{Path, PathBuf};

/// Discovers the current git branch (or a short detached-HEAD hash) by
/// walking up from `start` looking for a `.git` entry.
pub fn current_branch(start: &Path) -> Option<String> {
    let mut dir = to_absolute(start);

    loop {
        if let Some(head) = resolve_git_head(&dir.join(".git")) {
            return read_head(&head);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// Makes `path` absolute without touching the filesystem, with no existence
/// check and no symlink resolution, matching the original script's
/// `os.path.abspath`. Deliberately *not* [`Path::canonicalize`]: that
/// requires the path to exist, and on failure it would be tempting to fall
/// back to the process's own current directory, which would silently walk
/// up from the wrong place entirely for any `start` that doesn't (yet, or
/// ever) exist on disk rather than just treating it as already absolute.
fn to_absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    }
}

/// Given a candidate `.git` path (directory in an ordinary repo, file in a
/// worktree or submodule), returns the path to the `HEAD` file that
/// actually holds the branch reference.
fn resolve_git_head(git_path: &Path) -> Option<PathBuf> {
    if git_path.is_dir() {
        return Some(git_path.join("HEAD"));
    }
    if git_path.is_file() {
        let contents = std::fs::read_to_string(git_path).ok()?;
        let target = contents.trim().strip_prefix("gitdir:")?.trim();
        let mut gitdir = PathBuf::from(target);
        if gitdir.is_relative() {
            gitdir = git_path.parent()?.join(gitdir);
        }
        return Some(gitdir.join("HEAD"));
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
}
