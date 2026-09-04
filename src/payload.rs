// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/payload.rs
//
//

//! Typed schema for Claude Code's status-line JSON payload.
//!
//! Every nested struct field is `#[serde(default)]`, and every leaf value is
//! `Option<T>` (which `serde` already treats as implicitly optional). A
//! missing key anywhere in the payload therefore degrades to `None`/an empty
//! nested struct rather than an error; only a genuinely wrong-shaped payload
//! (e.g. a top-level JSON array instead of an object) fails to parse, and
//! that failure is handled once, at [`Payload::parse`]'s call site, instead
//! of resurfacing as a class of `unwrap`-adjacent panics scattered through
//! the render pipeline the way the original script's `dict.get(...) or {}`
//! chains could.

use serde::Deserialize;

/// The full status-line payload Claude Code pipes to this program's stdin.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Payload {
    #[serde(default)]
    pub context_window: ContextWindow,
    #[serde(default)]
    pub rate_limits: RateLimits,
    #[serde(default)]
    pub cost: Cost,
    #[serde(default)]
    pub workspace: Workspace,
    /// Legacy/fallback top-level `cwd`, used only if `workspace.current_dir` is absent.
    pub cwd: Option<String>,
    #[serde(default)]
    pub model: Model,
    #[serde(default)]
    pub effort: Effort,
    /// Unique, stable-for-the-session identifier Claude Code assigns this
    /// session. Used only to key `repo_status`'s on-disk cache so concurrent
    /// sessions in different repositories don't read each other's cached
    /// git state; absent before the first user input.
    pub session_id: Option<String>,
}

impl Payload {
    /// Parses a raw JSON payload. Returns `Err` for anything that isn't a
    /// well-formed status-line object; callers are expected to fall back to
    /// [`Payload::default`] on failure rather than propagate it, since a
    /// degraded status line beats no status line.
    pub fn parse(raw: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(raw)
    }
}

/// Context-window usage for the current conversation.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ContextWindow {
    pub used_percentage: Option<f64>,
    pub total_input_tokens: Option<u64>,
    pub total_output_tokens: Option<u64>,
    #[serde(default)]
    pub current_usage: CurrentUsage,
}

/// Token usage attributable to the current turn only.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct CurrentUsage {
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub cache_creation_input_tokens: Option<u64>,
    pub cache_read_input_tokens: Option<u64>,
}

/// The two rate-limit windows Claude Code reports.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RateLimits {
    #[serde(default)]
    pub five_hour: RateLimitWindow,
    #[serde(default)]
    pub seven_day: RateLimitWindow,
}

/// Usage and reset time for a single rate-limit window.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RateLimitWindow {
    pub used_percentage: Option<f64>,
    /// Unix epoch seconds at which this window resets.
    pub resets_at: Option<i64>,
}

/// Session cost/timing metadata.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Cost {
    pub total_duration_ms: Option<i64>,
}

/// Workspace location metadata.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Workspace {
    pub current_dir: Option<String>,
}

/// The active model's identity.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Model {
    pub display_name: Option<String>,
    pub id: Option<String>,
}

/// The live reasoning-effort level for the current session, as resolved by
/// Claude Code itself (explicit choice, saved per-model setting, or model
/// default). Absent when the current model doesn't support the effort
/// parameter.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Effort {
    pub level: Option<String>,
}
