// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/tests/golden.rs
//
//

//! Golden-fixture tests: each `tests/fixtures/*.json` payload (edge cases
//! drawn from `.claude_conjecture/initial_errors.md`, plus a representative
//! ordinary payload) is rendered end-to-end and compared against a
//! hand-computed expected single-line output.
//!
//! `tests/fixtures/*.json` itself is exempt from this project's per-file
//! header convention (see `porting.md`) for the same reason `Cargo.lock`
//! is: strict JSON has no comment syntax to carry one in, and these are
//! data files, not authored source.
//!
//! Every fixture is rendered with `force_no_color: true` so assertions
//! compare plain text, not escape sequences; color rendering itself is
//! covered by `src/theme.rs`'s own unit tests. Reset-time text
//! (`rate_limits.*.resets_at`) is deliberately omitted from every fixture
//! here: it renders in the *local* timezone by design (matching the
//! original script), which makes it inherently unsuitable for a
//! machine-independent exact-string comparison; that formatting logic has
//! its own timezone-agnostic unit tests in `src/format/time.rs`.

use claude_status_line::{payload::Payload, render_payload};
use std::path::PathBuf;

/// A cwd that deliberately does not exist on disk, so the settings cascade
/// `render_payload` consults for effort-level fallback (see
/// `src/config.rs`) never picks up a real `.claude/settings.json` from
/// whatever machine happens to be running this test suite.
fn hermetic_cwd() -> PathBuf {
    std::env::temp_dir().join("claude-status-line-golden-cwd-does-not-exist")
}

/// An empty, `.claude`-free directory used as `$HOME` for the duration of
/// this test, so the settings cascade never picks up a real
/// `~/.claude/settings.json` from the machine running the suite.
fn hermetic_home() -> PathBuf {
    let dir = std::env::temp_dir().join("claude-status-line-golden-home");
    std::fs::create_dir_all(&dir).expect("create hermetic HOME dir");
    dir
}

/// Points `$HOME` at `value` for the guard's lifetime, restoring the
/// original value on drop, panic or not, so a failing fixture assertion
/// can't leave `$HOME` pointed at the hermetic directory for whatever runs
/// next in this process.
struct HomeGuard {
    original: Option<std::ffi::OsString>,
}

impl HomeGuard {
    fn set(value: &std::path::Path) -> Self {
        let original = std::env::var_os("HOME");
        // SAFETY: this binary's only test touches `HOME`, so there is no
        // concurrent reader to race.
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

fn render_fixture(name: &str) -> String {
    let path = format!("{}/tests/fixtures/{name}.json", env!("CARGO_MANIFEST_DIR"));
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path}: {e}"));
    let mut payload = Payload::parse(&raw).unwrap_or_else(|e| panic!("parsing {name}.json: {e}"));
    payload.workspace.current_dir = Some(hermetic_cwd().display().to_string());
    payload.cwd = None;
    render_payload(&payload, true)
}

#[test]
fn golden_fixtures_match_expected_output() {
    // `dirs::home_dir()` (and therefore the settings cascade) reads `$HOME`
    // at call time. Overriding it to an empty, controlled directory keeps
    // every fixture's output independent of whatever `~/.claude/settings.json`
    // happens to say on the machine running this suite. `HomeGuard` restores
    // it on drop, so a failing assertion below still cleans up.
    let _home_guard = HomeGuard::set(&hermetic_home());

    // `render_fixture` forces `workspace.current_dir` to `hermetic_cwd()`,
    // a nonexistent temp path with no git repo above it, so every fixture
    // below exercises the `WHERE` row's no-repo pwd fallback: just that path
    // (unshortened, since it isn't under the hermetic `$HOME` either).
    let where_line = hermetic_cwd().display().to_string();

    let cases: [(&str, &str); 5] = [
        (
            "normal",
            "Claude Sonnet 5 ? \u{b7} [IN 949 +1] [OUT 13.1k +36] [CACHE +277 / 64.6k] \
             [CTX 42%] [5H 30%] [7D 12%]\n",
        ),
        (
            "missing_rate_limits",
            "Claude Haiku 4.5 ? \u{b7} [IN 100] [OUT 200] [CACHE 0] \
             [CTX 8%] [5H ?] [7D ?]\n",
        ),
        (
            "all_zero_usage",
            "Claude Sonnet 5 ? \u{b7} [IN 0] [OUT 0] [CACHE 0] \
             [CTX 0%] [5H 0%] [7D 0%]\n",
        ),
        (
            "huge_tokens",
            "Claude Opus 5 ? \u{b7} [IN 12.3m +15,000] [OUT 2.5m +9,999] [CACHE +1.0m / 1000.0k] \
             [CTX 98%] [5H 88%] [7D 80%]\n",
        ),
        (
            "empty_object",
            "? ? \u{b7} [IN 0] [OUT 0] [CACHE 0] [CTX ?] [5H ?] [7D ?]\n",
        ),
    ];

    for (name, expected_second_line) in &cases {
        let expected = format!("{where_line}\n{expected_second_line}");
        let actual = render_fixture(name);
        assert_eq!(
            actual, expected,
            "fixture {name} did not match expected output"
        );
    }
}
