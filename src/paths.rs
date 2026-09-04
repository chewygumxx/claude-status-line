// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/paths.rs
//
//

//! Path display helpers.

use std::path::Path;

/// Shortens a path under the user's home directory to a leading `~`, e.g.
/// `/home/alice/proj` becomes `~/proj`.
///
/// Compares path *components*, not raw characters: the original script's
/// `str.startswith(home)` check had no notion of a path boundary, so a
/// merely similarly-named sibling directory (`/home/alice-backup` against
/// home `/home/alice`) was wrongly treated as being under the home
/// directory. [`Path::strip_prefix`] can't make that mistake: it only
/// matches whole path components.
pub fn shorten_home(path: &str) -> String {
    let Some(home) = dirs::home_dir() else {
        return path.to_string();
    };
    let p = Path::new(path);
    match p.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".to_string(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sibling_directory_with_shared_prefix_is_not_shortened() {
        // Regression test for the original `str.startswith` bug: a
        // directory name that merely *starts with* the same characters as
        // home (but isn't actually under it) must be left untouched.
        // We can't override dirs::home_dir() here, so this exercises the
        // underlying Path::strip_prefix logic directly instead.
        let home = Path::new("/home/chewygum");
        let sibling = Path::new("/home/chewygumxx/project");
        assert!(sibling.strip_prefix(home).is_err());
    }

    #[test]
    fn exact_home_shortens_to_tilde_alone() {
        let home = Path::new("/home/chewygum");
        let rest = home.strip_prefix(home).unwrap();
        assert!(rest.as_os_str().is_empty());
    }

    #[test]
    fn nested_path_shortens_with_slash() {
        let home = Path::new("/home/chewygum");
        let nested = Path::new("/home/chewygum/dev/claude-status-line");
        let rest = nested.strip_prefix(home).unwrap();
        assert_eq!(format!("~/{}", rest.display()), "~/dev/claude-status-line");
    }
}
