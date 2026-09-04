// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/repo_status.rs
//
//

//! Dirty-file count and unpushed-commit check for the `WHERE` row's leading
//! counter.
//!
//! Unlike `git.rs` (deliberately subprocess-free for render-hot-path
//! latency, see its module doc comment), there is no reasonable way to
//! compute "how many tracked files are dirty" or "is HEAD ahead of the
//! cached `origin/<branch>`" without either reimplementing a meaningful
//! slice of git's index/object/pack format, or asking `git` directly. This
//! module is the one deliberate exception to the rest of the program's
//! subprocess-free rule.
//!
//! The ahead-check only ever compares against the *locally cached*
//! `refs/remotes/origin/<branch>`; it never performs a network fetch, so it
//! reflects the state as of the last `git fetch`/`push`, not live origin
//! state.
//!
//! Claude Code's own status-line docs warn that the status-line command
//! "runs frequently during active sessions" (event-driven: a new assistant
//! message, `/compact`, permission-mode changes, and more, debounced at
//! 300ms, not just once per user prompt) and specifically call out `git
//! status`/`git diff` as slow enough on large repos to need caching. This
//! module follows their recommended pattern: cache results to a temp file
//! keyed by `session_id` (stable for a session's lifetime, unique across
//! concurrent sessions) plus a hash of the repo root (so `cd`ing to a
//! different repo mid-session doesn't read another repo's cached state),
//! refreshed at most every [`CACHE_TTL`].

use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// How long a cached [`RepoStatus`] (or cached "couldn't determine one") is
/// reused before `query` shells out to `git` again. Matches the interval
/// used in Claude Code's own documented example of this caching pattern.
const CACHE_TTL: Duration = Duration::from_secs(5);

/// Local dirty/unpushed state for the `WHERE` row's leading counter.
#[derive(Clone)]
pub struct RepoStatus {
    /// Count of tracked files with staged and/or unstaged changes, each
    /// counted once even if both.
    pub dirty_count: usize,
    /// `true` when HEAD has commits not reachable from the cached
    /// `origin/<branch>`, or when that comparison couldn't be made at all
    /// (missing remote-tracking ref, unborn HEAD, no `origin` remote, `git`
    /// exits non-zero, etc.) -- every such case is treated as unpushed
    /// rather than silently hiding the marker.
    pub unpushed: bool,
}

/// Queries dirty-file count and unpushed status for the repo at `root` on
/// branch `branch` (if known), reusing a cached result from within the last
/// [`CACHE_TTL`] when `session_id` is `Some` (see the module doc comment).
/// With `session_id: None` (e.g. an older Claude Code version, or a direct
/// caller that doesn't want caching), this always queries `git` fresh.
///
/// Returns `None` only when the dirty-count query itself can't be run at
/// all (`git` missing from `PATH`, spawn failure, non-zero exit), so the
/// caller omits the whole counter rather than show a wrong one; an
/// unresolvable *unpushed* check on its own degrades to `unpushed: true`
/// instead of `None`, since `dirty_count` can still be valid even when the
/// ahead-check can't be made.
pub fn query(root: &Path, branch: Option<&str>, session_id: Option<&str>) -> Option<RepoStatus> {
    let Some(session_id) = session_id else {
        return query_uncached(root, branch);
    };
    let cache_path = cache_path(root, session_id);

    if let Some(cached) = read_fresh_cache(&cache_path) {
        return cached.into();
    }

    let result = query_uncached(root, branch);
    write_cache(&cache_path, &result);
    result
}

fn query_uncached(root: &Path, branch: Option<&str>) -> Option<RepoStatus> {
    let dirty_count = dirty_count(root)?;
    let unpushed = branch.is_none_or(|b| is_unpushed(root, b));
    Some(RepoStatus {
        dirty_count,
        unpushed,
    })
}

/// A cached query result, distinguishing "cached, and there was no status"
/// from "no usable cache entry at all" (the latter is represented as a
/// plain `None` returned from [`read_fresh_cache`], not by this type).
enum Cached {
    Absent,
    Present(RepoStatus),
}

impl From<Cached> for Option<RepoStatus> {
    fn from(cached: Cached) -> Self {
        match cached {
            Cached::Absent => None,
            Cached::Present(status) => Some(status),
        }
    }
}

/// The on-disk cache file for `(root, session_id)`, under the system temp
/// directory. `session_id` is sanitized to a safe filename fragment first:
/// it comes from an external JSON payload, so it's treated as untrusted
/// input rather than assumed to already be a bare identifier.
fn cache_path(root: &Path, session_id: &str) -> PathBuf {
    let safe_session_id: String = session_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    root.hash(&mut hasher);
    let root_hash = hasher.finish();

    std::env::temp_dir().join(format!(
        "claude-status-line-repo-status-{safe_session_id}-{root_hash:x}"
    ))
}

/// Reads `path` and returns its cached value if the file exists and was
/// written within [`CACHE_TTL`]. `None` covers every reason the cache can't
/// be used (missing file, stale, unreadable, malformed contents), so the
/// caller always falls through to a fresh `git` query in those cases.
fn read_fresh_cache(path: &Path) -> Option<Cached> {
    let metadata = std::fs::metadata(path).ok()?;
    let age = metadata.modified().ok()?.elapsed().ok()?;
    if age > CACHE_TTL {
        return None;
    }
    parse_cache(std::fs::read_to_string(path).ok()?.trim())
}

/// Parses this module's own cache-file format: the sentinel `NONE` line, or
/// `<dirty_count>|<0 or 1>`. `None` for anything else, treated as an
/// unusable/corrupt cache by [`read_fresh_cache`].
fn parse_cache(s: &str) -> Option<Cached> {
    if s == "NONE" {
        return Some(Cached::Absent);
    }
    let (count, unpushed) = s.split_once('|')?;
    Some(Cached::Present(RepoStatus {
        dirty_count: count.parse().ok()?,
        unpushed: unpushed == "1",
    }))
}

/// Best-effort cache write: a failure here (read-only temp dir, race with
/// another process) just means the next render queries `git` again, so it's
/// silently ignored rather than propagated.
fn write_cache(path: &Path, status: &Option<RepoStatus>) {
    let contents = match status {
        None => "NONE".to_string(),
        Some(s) => format!("{}|{}", s.dirty_count, u8::from(s.unpushed)),
    };
    let _ = std::fs::write(path, contents);
}

/// Counts tracked files with staged and/or unstaged changes via
/// `git status --porcelain`, which emits exactly one line per changed
/// path (renames included) regardless of whether the change is staged,
/// unstaged, or both. `None` if the command can't be run or exits
/// non-zero.
fn dirty_count(root: &Path) -> Option<usize> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["status", "--porcelain", "--untracked-files=no"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    Some(stdout.lines().filter(|line| !line.is_empty()).count())
}

/// True when HEAD has commits not reachable from the locally cached
/// `origin/<branch>`, or when that can't be determined at all (no such
/// remote-tracking ref, `git` exits non-zero, unparseable output).
fn is_unpushed(root: &Path, branch: &str) -> bool {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-list", "--count"])
        .arg(format!("origin/{branch}..HEAD"))
        .output();
    let Ok(output) = output else {
        return true;
    };
    if !output.status.success() {
        return true;
    }
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .ok()
        .is_none_or(|ahead| ahead > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn tempdir() -> std::path::PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "claude-status-line-repo-status-test-{}-{n}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn git(root: &Path, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .status()
            .expect("git must be on PATH for repo_status tests");
        assert!(status.success(), "git {args:?} failed");
    }

    fn init_repo(root: &Path) {
        git(root, &["init", "--initial-branch=main", "--quiet"]);
        git(root, &["config", "user.email", "test@example.com"]);
        git(root, &["config", "user.name", "Test"]);
    }

    #[test]
    fn clean_and_pushed_repo_reports_zero_and_not_unpushed() {
        let root = tempdir();
        init_repo(&root);
        fs::write(root.join("a.txt"), "hello\n").unwrap();
        git(&root, &["add", "a.txt"]);
        git(&root, &["commit", "--quiet", "-m", "initial"]);

        // Fake a pushed `origin/main` ref by pointing it at the same commit,
        // without any actual network remote.
        git(
            &root,
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );

        let status = query(&root, Some("main"), None).expect("expected a status");
        assert_eq!(status.dirty_count, 0);
        assert!(!status.unpushed);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn modified_tracked_file_is_counted_dirty() {
        let root = tempdir();
        init_repo(&root);
        fs::write(root.join("a.txt"), "hello\n").unwrap();
        git(&root, &["add", "a.txt"]);
        git(&root, &["commit", "--quiet", "-m", "initial"]);
        git(
            &root,
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );

        fs::write(root.join("a.txt"), "changed\n").unwrap();

        let status = query(&root, Some("main"), None).expect("expected a status");
        assert_eq!(status.dirty_count, 1);
        assert!(!status.unpushed);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn commit_after_origin_ref_is_unpushed() {
        let root = tempdir();
        init_repo(&root);
        fs::write(root.join("a.txt"), "hello\n").unwrap();
        git(&root, &["add", "a.txt"]);
        git(&root, &["commit", "--quiet", "-m", "initial"]);
        git(
            &root,
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );

        fs::write(root.join("b.txt"), "more\n").unwrap();
        git(&root, &["add", "b.txt"]);
        git(&root, &["commit", "--quiet", "-m", "second"]);

        let status = query(&root, Some("main"), None).expect("expected a status");
        assert_eq!(status.dirty_count, 0);
        assert!(status.unpushed);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn no_origin_remote_is_treated_as_unpushed() {
        let root = tempdir();
        init_repo(&root);
        fs::write(root.join("a.txt"), "hello\n").unwrap();
        git(&root, &["add", "a.txt"]);
        git(&root, &["commit", "--quiet", "-m", "initial"]);

        let status = query(&root, Some("main"), None).expect("expected a status");
        assert_eq!(status.dirty_count, 0);
        assert!(status.unpushed);
        fs::remove_dir_all(&root).ok();
    }

    fn unique_session_id(label: &str) -> String {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        format!("test-session-{label}-{}-{n}", std::process::id())
    }

    #[test]
    fn cached_result_is_reused_within_ttl() {
        let root = tempdir();
        init_repo(&root);
        fs::write(root.join("a.txt"), "hello\n").unwrap();
        git(&root, &["add", "a.txt"]);
        git(&root, &["commit", "--quiet", "-m", "initial"]);
        git(
            &root,
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );

        let session_id = unique_session_id("fresh");
        let first = query(&root, Some("main"), Some(&session_id)).expect("expected a status");
        assert_eq!(first.dirty_count, 0);

        // Dirty the tree after the first (cache-populating) call.
        fs::write(root.join("a.txt"), "changed\n").unwrap();

        let second = query(&root, Some("main"), Some(&session_id)).expect("expected a status");
        assert_eq!(
            second.dirty_count, 0,
            "expected the cached (stale) count, not a fresh `git status`"
        );
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn expired_cache_is_refreshed() {
        let root = tempdir();
        init_repo(&root);
        fs::write(root.join("a.txt"), "hello\n").unwrap();
        git(&root, &["add", "a.txt"]);
        git(&root, &["commit", "--quiet", "-m", "initial"]);
        git(
            &root,
            &["update-ref", "refs/remotes/origin/main", "refs/heads/main"],
        );

        let session_id = unique_session_id("expired");
        let first = query(&root, Some("main"), Some(&session_id)).expect("expected a status");
        assert_eq!(first.dirty_count, 0);

        // Back-date the cache file past `CACHE_TTL` instead of sleeping.
        let cache_file = cache_path(&root, &session_id);
        let old = std::time::SystemTime::now() - (CACHE_TTL + Duration::from_secs(1));
        let times = std::fs::FileTimes::new().set_modified(old);
        std::fs::File::options()
            .write(true)
            .open(&cache_file)
            .unwrap()
            .set_times(times)
            .unwrap();

        fs::write(root.join("a.txt"), "changed\n").unwrap();

        let second = query(&root, Some("main"), Some(&session_id)).expect("expected a status");
        assert_eq!(
            second.dirty_count, 1,
            "expected a fresh `git status` once the cache expired"
        );
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn cache_path_sanitizes_unsafe_session_id() {
        let root = tempdir();
        let path = cache_path(&root, "../../etc/passwd ok");
        assert_eq!(path.parent(), Some(std::env::temp_dir().as_path()));
        let name = path.file_name().unwrap().to_string_lossy();
        assert!(!name.contains('/'), "sanitized name still has a slash");
        assert!(!name.contains(".."), "sanitized name still has `..`");
        fs::remove_dir_all(&root).ok();
    }
}
