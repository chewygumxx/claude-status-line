// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/lib.rs
//
//

//! Claude Code status line: parses the JSON payload Claude Code pipes to
//! this program on every prompt render and renders a two-line, color-coded
//! summary: repository/branch/path (or pwd) on the first line, then
//! model/effort configuration, context/rate-limit usage, and token counts
//! on the second.
//!
//! Structured as a library with a thin [`main.rs`](../src/main.rs) binary
//! wrapper specifically so [`render()`] and the modules it calls can be
//! exercised directly by `tests/golden.rs` without going through a process
//! and a stdin pipe for every fixture.

pub mod config;
pub mod format;
pub mod git;
pub mod paths;
pub mod payload;
pub mod render;
pub mod repo_status;
pub mod theme;

use payload::Payload;
use std::path::PathBuf;
use time::OffsetDateTime;

/// Parses `raw_payload` and renders the full two-line status line
/// (newline-terminated). Never panics and never fails outright: a malformed
/// or wrong-shaped payload degrades to the same output as an empty one
/// rather than propagating an error, since a status line that's wrong in a
/// few fields is strictly better than a crash that shows nothing at all.
pub fn render(raw_payload: &str, force_no_color: bool) -> String {
    let payload = Payload::parse(raw_payload).unwrap_or_default();
    render_payload(&payload, force_no_color)
}

/// Treats an empty string the same as absent.
///
/// The original script's fallback chains (`x or y or z`) use Python's `or`,
/// which falls through on *any* falsy value, not just a missing key: an
/// explicit `""` is just as falsy as `None` there. A direct `Option`
/// translation (`.or_else`/`.unwrap_or_else`) only falls through on `None`,
/// so every fallback chain below routes through this first to keep that
/// same falsy-string behavior, not just missing-key behavior.
fn non_empty(s: Option<String>) -> Option<String> {
    s.filter(|v| !v.is_empty())
}

/// Same as [`render()`], but from an already-parsed [`Payload`]: the entry
/// point the golden-fixture tests use directly.
pub fn render_payload(payload: &Payload, force_no_color: bool) -> String {
    let tier = if force_no_color {
        theme::Tier::Plain
    } else {
        theme::detect_tier()
    };

    let cwd_raw = non_empty(payload.workspace.current_dir.clone())
        .or_else(|| non_empty(payload.cwd.clone()))
        .unwrap_or_else(|| {
            std::env::current_dir()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        });
    let cwd_path = PathBuf::from(&cwd_raw);

    let model_name = non_empty(payload.model.display_name.clone())
        .or_else(|| non_empty(payload.model.id.clone()))
        .unwrap_or_else(|| "?".to_string());

    // `payload.effort.level` is Claude Code's own fully resolved live value
    // (explicit choice, saved per-model setting, or model default already
    // applied), so it's preferred over re-deriving an approximation from the
    // settings cascade; the cascade only covers older Claude Code versions
    // that don't send `effort.level` at all.
    let effort = non_empty(payload.effort.level.clone())
        .or_else(|| {
            let model_id = payload.model.id.as_deref()?;
            non_empty(config::Settings::load(&cwd_path).effort_level(model_id))
        })
        .unwrap_or_else(|| "?".to_string())
        .to_uppercase();

    let cu = &payload.context_window.current_usage;
    let ctx_gauge = format::gauge::Gauge::from_percentage(payload.context_window.used_percentage);
    let five = &payload.rate_limits.five_hour;
    let seven = &payload.rate_limits.seven_day;
    let five_gauge = format::gauge::Gauge::from_percentage(five.used_percentage);
    let seven_gauge = format::gauge::Gauge::from_percentage(seven.used_percentage);

    let now = OffsetDateTime::now_utc();
    let five_reset = format::time::fmt_reset(five.resets_at, now);
    let seven_reset = format::time::fmt_reset(seven.resets_at, now);

    let cwd_abs = git::to_absolute(&cwd_path);
    let where_part = match git::locate(&cwd_path) {
        Some(info) => {
            let owner = info.owner.unwrap_or_else(|| "chewygumxx".to_string());
            let repo_name = info.repo.unwrap_or_else(|| {
                info.root
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            });
            let rel_path = paths::relative_to(&cwd_abs, &info.root)
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            let counter = repo_status::query(
                &info.root,
                info.branch.as_deref(),
                payload.session_id.as_deref(),
            )
            .and_then(|s| {
                (s.dirty_count > 0 || s.unpushed).then_some(render::DirtyCounter {
                    count: s.dirty_count,
                    unpushed: s.unpushed,
                })
            });
            render::row_where(
                tier,
                render::Where::Repo(render::RepoLocation {
                    branch: info.branch.as_deref(),
                    owner: &owner,
                    repo: &repo_name,
                    path: &rel_path,
                    counter,
                }),
            )
        }
        None => render::row_where(tier, render::Where::Pwd(&paths::shorten_home(&cwd_raw))),
    };

    let config_part = render::row_config(tier, &model_name, &effort);
    let tokens_part = render::row_tokens(
        tier,
        payload.context_window.total_input_tokens.unwrap_or(0),
        payload.context_window.total_output_tokens.unwrap_or(0),
        cu.input_tokens.unwrap_or(0),
        cu.output_tokens.unwrap_or(0),
        cu.cache_creation_input_tokens.unwrap_or(0),
        cu.cache_read_input_tokens.unwrap_or(0),
    );
    let limits_part = render::row_limits(
        tier,
        &ctx_gauge,
        &five_gauge,
        &five_reset,
        &seven_gauge,
        &seven_reset,
    );

    let sep = render::separator(tier);
    format!("{where_part}\n{config_part}{sep}{tokens_part} {limits_part}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_payload_renders_two_lines_without_panicking() {
        let out = render("{}", true);
        assert_eq!(out.lines().count(), 2);
    }

    #[test]
    fn non_object_top_level_json_degrades_gracefully() {
        // Regression test for Error #1: a syntactically valid but
        // wrong-shaped top-level payload (array, null, etc.) must not panic.
        for raw in ["null", "[]", "42", "\"oops\"", ""] {
            let out = render(raw, true);
            assert_eq!(
                out.lines().count(),
                2,
                "payload {raw:?} did not degrade to two lines"
            );
        }
    }

    #[test]
    fn non_empty_treats_empty_string_as_absent() {
        assert_eq!(non_empty(Some(String::new())), None);
        assert_eq!(non_empty(Some("x".to_string())), Some("x".to_string()));
        assert_eq!(non_empty(None), None);
    }

    #[test]
    fn empty_display_name_falls_through_to_model_id() {
        let mut payload = Payload::default();
        payload.model.display_name = Some(String::new());
        payload.model.id = Some("claude-sonnet-5".to_string());
        let out = render_payload(&payload, true);
        let line = out.lines().nth(1).unwrap();
        assert!(
            line.starts_with("claude-sonnet-5"),
            "expected fallback to `model.id`, got {line:?}"
        );
    }

    #[test]
    fn payload_effort_level_is_shown_without_any_settings_file() {
        // Regression test: the live `effort.level` payload field must be
        // usable on its own, with no settings.json cascade involved at all.
        let mut payload = Payload::default();
        payload.effort.level = Some("high".to_string());
        let out = render_payload(&payload, true);
        let line = out.lines().nth(1).unwrap();
        assert!(
            line.contains("HIGH"),
            "expected payload effort level to render, got {line:?}"
        );
    }
}
