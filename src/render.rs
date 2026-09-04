// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/render.rs
//
//

//! Assembles the status-line's field groups: model/effort, the token
//! counts, and the limit gauges, joined by [`crate::render_payload`] into
//! a single printed line.
//!
//! The original script hand-rolled each group's string concatenation
//! separately, which is how it ended up with two byte-for-byte identical
//! `bracket()`/`_bracket()` helpers and an unused, differently-behaved
//! `fmt_pct()` sitting unnoticed next to the `fmt_pct_tight()` that was
//! actually used. Every group here goes through the same `bracketed` and
//! `separator` primitives instead, so there's exactly one implementation
//! of "put dim brackets around this" and "join these with a dim separator"
//! to maintain.

use crate::format::gauge::Gauge;
use crate::format::tokens;
use crate::theme::{self, Role, Tier};

/// Wraps `inner` in dim `[` `]` brackets.
fn bracketed(tier: Tier, inner: &str) -> String {
    format!("{}{inner}{}", theme::dim(tier, "["), theme::dim(tier, "]"))
}

/// The dim ` · ` separator used between row fields.
pub(crate) fn separator(tier: Tier) -> String {
    theme::dim(tier, " \u{b7} ")
}

fn gauge_field(tier: Tier, label: &str, gauge: &Gauge, reset: &str) -> String {
    let pct_text = match gauge.display {
        Some(d) => format!("{d}%"),
        None => "?".to_string(),
    };
    let mut inner = format!(
        "{} {}",
        theme::role(tier, Role::Muted, false, label),
        theme::role(tier, gauge.severity.role(), true, &pct_text)
    );
    if !reset.is_empty() {
        inner.push(' ');
        inner.push_str(&theme::role(tier, Role::Muted, false, reset));
    }
    bracketed(tier, &inner)
}

/// Row 1 (`LIMITS`): context-window, 5-hour, and 7-day usage gauges.
pub fn row_limits(
    tier: Tier,
    ctx: &Gauge,
    five_hour: &Gauge,
    five_hour_reset: &str,
    seven_day: &Gauge,
    seven_day_reset: &str,
) -> String {
    format!(
        "{} {} {}",
        gauge_field(tier, "CTX", ctx, ""),
        gauge_field(tier, "5H", five_hour, five_hour_reset),
        gauge_field(tier, "7D", seven_day, seven_day_reset),
    )
}

fn delta(tier: Tier, n: u64) -> String {
    if n == 0 {
        return String::new();
    }
    format!(
        " {}",
        theme::role(
            tier,
            Role::Muted,
            false,
            &format!("+{}", tokens::fmt_commas(n))
        )
    )
}

fn labeled_field(tier: Tier, label: &str, value: &str) -> String {
    bracketed(
        tier,
        &format!("{}{value}", theme::role(tier, Role::Muted, false, label)),
    )
}

/// Row 2 (`TOKENS`): input/output totals with per-turn deltas, plus cache usage.
#[allow(clippy::too_many_arguments)]
pub fn row_tokens(
    tier: Tier,
    total_in: u64,
    total_out: u64,
    turn_in: u64,
    turn_out: u64,
    cache_write: u64,
    cache_read: u64,
) -> String {
    let in_value = format!(
        "{}{}",
        theme::bold(tier, &tokens::fmt_compact(total_in)),
        delta(tier, turn_in)
    );
    let in_part = labeled_field(tier, "IN ", &in_value);

    let out_number = theme::role(tier, Role::Danger, true, &tokens::fmt_compact(total_out));
    let out_value = format!("{out_number}{}", delta(tier, turn_out));
    let out_part = labeled_field(tier, "OUT ", &out_value);

    let mut cache_value = String::new();
    if cache_write != 0 {
        cache_value.push_str(&theme::role(
            tier,
            Role::Warning,
            false,
            &format!("+{}", tokens::fmt_compact(cache_write)),
        ));
        cache_value.push_str(&theme::dim(tier, " / "));
    }
    cache_value.push_str(&theme::role(
        tier,
        Role::Success,
        false,
        &tokens::fmt_compact(cache_read),
    ));
    let cache_part = labeled_field(tier, "CACHE ", &cache_value);

    format!("{in_part} {out_part} {cache_part}")
}

/// The color role for an effort level (`LOW`/`MEDIUM`/`HIGH`/`MAX`/unknown).
fn effort_role(level: &str) -> Role {
    match level {
        "LOW" => Role::EffortLow,
        "MEDIUM" => Role::Warning,
        "HIGH" => Role::EffortHigh,
        "MAX" => Role::Danger,
        _ => Role::Muted,
    }
}

/// Model name and effort level, joined by a plain space; the caller
/// (`render_payload`) appends the dim `separator` (this module) before the
/// fields that follow.
pub fn row_config(tier: Tier, model: &str, effort: &str) -> String {
    format!(
        "{} {}",
        theme::role(tier, Role::Model, false, model),
        theme::role(tier, effort_role(effort), true, effort)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format::gauge::Severity;

    fn strip_ansi(s: &str) -> String {
        let mut out = String::new();
        let mut in_escape = false;
        for ch in s.chars() {
            if ch == '\x1b' {
                in_escape = true;
                continue;
            }
            if in_escape {
                if ch == 'm' {
                    in_escape = false;
                }
                continue;
            }
            out.push(ch);
        }
        out
    }

    #[test]
    fn gauge_field_shape_matches_original_bracket_layout() {
        let g = Gauge {
            display: Some(42),
            severity: Severity::Low,
        };
        let out = strip_ansi(&gauge_field(Tier::TrueColor, "CTX", &g, ""));
        assert_eq!(out, "[CTX 42%]");
    }

    #[test]
    fn gauge_field_unknown_shows_question_mark() {
        let g = Gauge {
            display: None,
            severity: Severity::Unknown,
        };
        let out = strip_ansi(&gauge_field(Tier::Plain, "5H", &g, ""));
        assert_eq!(out, "[5H ?]");
    }

    #[test]
    fn plain_tier_emits_no_escape_codes() {
        let g = Gauge {
            display: Some(10),
            severity: Severity::Low,
        };
        let out = gauge_field(Tier::Plain, "CTX", &g, "");
        assert!(!out.contains('\x1b'));
    }

    #[test]
    fn row_config_joins_model_and_effort_with_space() {
        let out = strip_ansi(&row_config(Tier::Plain, "Claude Sonnet 5", "HIGH"));
        assert_eq!(out, "Claude Sonnet 5 HIGH");
    }
}
