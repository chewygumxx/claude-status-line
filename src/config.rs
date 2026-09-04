// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/config.rs
//
//

//! Layered Claude Code settings.
//!
//! Generalizes the original script's `effortLevel`-only cascade into a
//! reusable merge over the same three sources, so any future setting this
//! program wants to read (not just effort level) gets the cascade for free
//! instead of a copy-pasted three-path lookup: project-local
//! `.claude/settings.local.json` (meant for uncommitted per-checkout
//! overrides) takes precedence over the project's committed
//! `.claude/settings.json`, which takes precedence over the user-wide
//! `~/.claude/settings.json` fallback.
//!
//! This is a fallback source for effort level, not the primary one: when the
//! status-line payload itself carries `effort.level`, that live, fully
//! resolved value (Claude Code already applied explicit choices, saved
//! per-model settings, and model defaults) should be preferred. This module
//! only approximates that resolution from the settings files directly, for
//! older Claude Code versions that don't send `effort.level` at all.

use serde_json::Value;
use std::path::{Path, PathBuf};

/// The merged settings cascade for a given working directory.
pub struct Settings {
    merged: Value,
}

impl Settings {
    /// Loads and merges the settings cascade for `cwd`. Missing, unreadable,
    /// or malformed files are silently skipped: a broken user-level
    /// settings file shouldn't be able to break status-line rendering.
    ///
    /// A key present in a higher-priority file but holding a falsy value
    /// (`null`, `""`, `0`, `false`, `[]`, `{}`) does not shadow a real value
    /// for that same key further down the cascade: this mirrors the
    /// original script's `if v: return v` per-candidate check in
    /// `read_effort_level`, which kept searching past a falsy value instead
    /// of treating "present" and "usable" as the same thing. Nested objects
    /// (e.g. `modelSettings.<model-id>`) are merged recursively so this
    /// truthy-fallthrough applies per leaf, not just per top-level key: see
    /// `merge_object` in this module's source.
    pub fn load(cwd: &Path) -> Self {
        let mut merged = Value::Object(serde_json::Map::new());
        for candidate in candidates(cwd) {
            let Ok(text) = std::fs::read_to_string(&candidate) else {
                continue;
            };
            let Ok(obj @ Value::Object(_)) = serde_json::from_str::<Value>(&text) else {
                continue;
            };
            merge_object(&mut merged, obj);
        }
        Settings { merged }
    }

    /// The configured effort level (e.g. `low`/`medium`/`high`/`xhigh`), if
    /// set anywhere in the cascade for `model_id`. Checks the model-specific
    /// `modelSettings.<model_id>.effortLevel` (what `/effort` saves for that
    /// model) before falling back to the top-level `effortLevel` default,
    /// matching Claude Code's own settings resolution order.
    pub fn effort_level(&self, model_id: &str) -> Option<String> {
        self.merged
            .get("modelSettings")
            .and_then(|m| m.get(model_id))
            .and_then(|m| m.get("effortLevel"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                self.merged
                    .get("effortLevel")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
    }
}

/// Python truthiness for a parsed JSON value: `null`, `""`, `0`, `false`,
/// `[]`, and `{}` are all falsy, matching Python's `if v:` in the original
/// script (which this generalizes; see [`Settings::load`]).
fn is_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_none_or(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// Recursively merges `incoming` into `target`, keeping the first truthy
/// value seen for each leaf and only descending into a key when both sides
/// hold an object there. Per-top-level-key `or_insert` isn't enough once a
/// leaf lives under a nested key (like `modelSettings.<model-id>.effortLevel`):
/// a higher-priority file that merely mentions the same nested object, even
/// with a falsy value at that leaf, must not block a real value the same
/// leaf holds in a lower-priority file.
fn merge_object(target: &mut Value, incoming: Value) {
    let (Value::Object(target_map), Value::Object(incoming_map)) = (target, incoming) else {
        return;
    };
    for (key, value) in incoming_map {
        match target_map.get_mut(&key) {
            Some(existing) if existing.is_object() && value.is_object() => {
                merge_object(existing, value);
            }
            Some(existing) if is_truthy(existing) => {}
            Some(existing) => {
                if is_truthy(&value) {
                    *existing = value;
                }
            }
            None => {
                target_map.insert(key, value);
            }
        }
    }
}

fn candidates(cwd: &Path) -> Vec<PathBuf> {
    let mut paths = vec![
        cwd.join(".claude").join("settings.local.json"),
        cwd.join(".claude").join("settings.json"),
    ];
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".claude").join("settings.json"));
    }
    paths
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// Guards tests that mutate `$HOME`, so they can't race each other even
    /// under the default parallel test runner.
    static HOME_ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Points `$HOME` at `value` for the guard's lifetime, restoring the
    /// original value on drop. Unlike a plain set-then-restore, this still
    /// restores `$HOME` if the calling test panics partway through (e.g. a
    /// failing `assert_eq!`) instead of leaking the override into every
    /// other test sharing this process, since this crate's unit tests (this
    /// module included) all run in one shared test binary.
    struct HomeGuard {
        original: Option<std::ffi::OsString>,
    }

    impl HomeGuard {
        fn set(value: &Path) -> Self {
            let original = std::env::var_os("HOME");
            // SAFETY: callers hold `HOME_ENV_LOCK` for the guard's lifetime,
            // so no other test observes `HOME` mid-mutation.
            unsafe {
                std::env::set_var("HOME", value);
            }
            HomeGuard { original }
        }
    }

    impl Drop for HomeGuard {
        fn drop(&mut self) {
            // SAFETY: see `HomeGuard::set`.
            unsafe {
                match &self.original {
                    Some(v) => std::env::set_var("HOME", v),
                    None => std::env::remove_var("HOME"),
                }
            }
        }
    }

    fn tempdir() -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "claude-status-line-config-test-{}-{n}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Every test below reads through `Settings::load`, which always
    /// includes `~/.claude/settings.json` in its cascade (see
    /// `candidates`). Without pinning `$HOME` to an empty, controlled
    /// directory, a test's assertions would depend on whatever the machine
    /// actually running this suite has saved there, `modelSettings` nested
    /// per-model entries included, not just top-level `effortLevel` as
    /// before.
    fn hermetic_home_guard() -> (std::sync::MutexGuard<'static, ()>, PathBuf, HomeGuard) {
        let lock = HOME_ENV_LOCK.lock().unwrap();
        let home = tempdir();
        let guard = HomeGuard::set(&home);
        (lock, home, guard)
    }

    #[test]
    fn project_local_wins_over_project() {
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("settings.local.json"),
            r#"{"effortLevel":"MAX"}"#,
        )
        .unwrap();
        fs::write(claude_dir.join("settings.json"), r#"{"effortLevel":"LOW"}"#).unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("MAX".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn missing_files_yield_no_effort_level() {
        let (_lock, home, _guard) = hermetic_home_guard();

        let cwd = tempdir();
        let settings = Settings::load(&cwd);
        assert_eq!(settings.effort_level("claude-sonnet-5"), None);

        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn falsy_value_falls_through_to_next_candidate() {
        // Regression test: a higher-priority file that sets `effortLevel`
        // to a falsy value (here, ``) must not shadow a real value further
        // down the cascade, matching the original script's `if v:` check.
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("settings.local.json"),
            r#"{"effortLevel":""}"#,
        )
        .unwrap();
        fs::write(
            claude_dir.join("settings.json"),
            r#"{"effortLevel":"HIGH"}"#,
        )
        .unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("HIGH".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn null_value_falls_through_to_next_candidate() {
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("settings.local.json"),
            r#"{"effortLevel":null}"#,
        )
        .unwrap();
        fs::write(claude_dir.join("settings.json"), r#"{"effortLevel":"MAX"}"#).unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("MAX".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn model_settings_effort_level_wins_over_top_level_default() {
        // Regression test: real Claude Code settings.json files save
        // per-model effort under `modelSettings.<model-id>.effortLevel`
        // (what `/effort` writes), which must take priority over the
        // top-level `effortLevel` default for that same model.
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("settings.json"),
            r#"{"effortLevel":"low","modelSettings":{"claude-sonnet-5":{"effortLevel":"high"}}}"#,
        )
        .unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("high".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn model_settings_falls_back_to_top_level_default_for_other_models() {
        // A `modelSettings` entry for one model must not shadow the
        // top-level default when resolving a *different* model's effort.
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("settings.json"),
            r#"{"effortLevel":"low","modelSettings":{"claude-opus-5":{"effortLevel":"xhigh"}}}"#,
        )
        .unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("low".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn model_settings_merges_across_cascade_and_falls_through_falsy_leaf() {
        // Regression test for the nested-merge fix: a higher-priority file's
        // falsy `modelSettings.<id>.effortLevel` must not block a real value
        // for that same model further down the cascade, and per-model
        // entries from different files must combine rather than the whole
        // `modelSettings` object being taken wholesale from one file.
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(
            claude_dir.join("settings.local.json"),
            r#"{"modelSettings":{"claude-sonnet-5":{"effortLevel":""}}}"#,
        )
        .unwrap();
        fs::write(
            claude_dir.join("settings.json"),
            r#"{"modelSettings":{"claude-sonnet-5":{"effortLevel":"medium"},"claude-opus-5":{"effortLevel":"xhigh"}}}"#,
        )
        .unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("medium".to_string())
        );
        assert_eq!(
            settings.effort_level("claude-opus-5"),
            Some("xhigh".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn malformed_json_is_skipped_not_fatal() {
        let (_lock, home, _guard) = hermetic_home_guard();
        let cwd = tempdir();
        let claude_dir = cwd.join(".claude");
        fs::create_dir_all(&claude_dir).unwrap();
        fs::write(claude_dir.join("settings.local.json"), "{not valid json").unwrap();
        fs::write(
            claude_dir.join("settings.json"),
            r#"{"effortLevel":"HIGH"}"#,
        )
        .unwrap();

        let settings = Settings::load(&cwd);
        assert_eq!(
            settings.effort_level("claude-sonnet-5"),
            Some("HIGH".to_string())
        );
        fs::remove_dir_all(&cwd).ok();
        fs::remove_dir_all(&home).ok();
    }
}
