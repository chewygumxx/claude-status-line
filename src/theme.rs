// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/theme.rs
//
//

//! Color palette and terminal-capability-aware rendering.
//!
//! The original Python script mixed classic ANSI16 escape codes (which track
//! whatever palette the user's terminal theme defines) with a couple of
//! fixed xterm-256 codes (which don't follow the user's theme at all) with no
//! particular rationale: an accident of which constant happened to be
//! reached for, not a deliberate design. This module makes the same choice
//! *deliberately* and *per role*: every [`Role`] declares a truecolor value,
//! a 256-color value, and a 16-color value, and [`role`] picks between them
//! based on what [`detect_tier`] finds this terminal actually supports.
//!
//! For roles that have a natural legacy ANSI16 equivalent (the six drawn
//! from the classic 8/16-color set), the 256-color tier intentionally reuses
//! the *palette-relative* xterm indices `0..=15` rather than a fixed RGB, so
//! on terminals without truecolor support, this program still follows the
//! user's own terminal theme, exactly as the original script's ANSI16
//! constants did. Only the truecolor tier gets a curated, terminal-theme-independent
//! RGB value. The two roles with no legacy equivalent ([`Role::EffortHigh`]
//! orange and [`Role::Muted`] gray) keep the original script's exact fixed
//! xterm-256 indices (208 and 244) at the 256-color tier, with a documented
//! best-effort ANSI16 substitute one tier further down.

use owo_colors::{AnsiColors, OwoColorize, Rgb, Style};
use supports_color::Stream;

/// How much color this terminal supports, from richest to none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    TrueColor,
    Ansi256,
    Ansi16,
    /// No color at all: either the terminal doesn't support it, or the
    /// user asked for it to be suppressed (`NO_COLOR`, `--no-color`).
    Plain,
}

/// Detects the color tier for stdout, honoring `NO_COLOR`/`CLICOLOR_FORCE`
/// (via the `supports-color` crate) in addition to actual terminal
/// capability.
///
/// `supports-color` also refuses color whenever stdout isn't a real tty.
/// That's sensible for a general-purpose CLI being redirected by a human,
/// but actively wrong for this program: its stdout is *always* captured by
/// Claude Code and re-rendered in its own UI, never written straight to a
/// terminal, so "is a tty" is not a meaningful signal here at all. Setting
/// `IGNORE_IS_TERMINAL` is `supports-color`'s own documented bypass for
/// exactly this situation, a known non-tty consumer that still wants real
/// ANSI output, so this still degrades correctly to plain text on an
/// explicit `NO_COLOR`/`CLICOLOR=0`, just not merely because stdout is a pipe.
///
/// # Safety-relevant note
/// This mutates the process environment. Like `crate::format::time::local_offset`,
/// it's only ever reached (via [`crate::render_payload`] with
/// `force_no_color: false`) from this program's single-threaded `main`, so
/// there's no concurrent reader to race, the same precondition documented
/// there.
pub fn detect_tier() -> Tier {
    if std::env::var_os("IGNORE_IS_TERMINAL").is_none() {
        // SAFETY: see the "Safety-relevant note" above; single-threaded at the point this runs.
        unsafe {
            std::env::set_var("IGNORE_IS_TERMINAL", "1");
        }
    }
    match supports_color::on(Stream::Stdout) {
        None => Tier::Plain,
        Some(level) if level.has_16m => Tier::TrueColor,
        Some(level) if level.has_256 => Tier::Ansi256,
        Some(_) => Tier::Ansi16,
    }
}

/// The semantic colors used across the status line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// Low/healthy usage; also the git branch.
    Success,
    /// Mid-range usage; also `MEDIUM` effort and cache-write counts.
    Warning,
    /// High/critical usage; also `MAX` effort and the OUT token count.
    Danger,
    /// `LOW` effort.
    EffortLow,
    /// `HIGH` effort (no ANSI16 equivalent).
    EffortHigh,
    /// The model name.
    Model,
    /// The current working directory.
    Path,
    /// Row labels, deltas, separators, and unknown/`?` values (no ANSI16 equivalent as a distinct gray).
    Muted,
}

struct ColorSpec {
    truecolor: (u8, u8, u8),
    ansi256: u8,
    ansi16: AnsiColors,
}

const fn spec(role: Role) -> ColorSpec {
    match role {
        Role::Success => ColorSpec {
            truecolor: (63, 185, 80),
            ansi256: 2,
            ansi16: AnsiColors::Green,
        },
        Role::Warning => ColorSpec {
            truecolor: (210, 153, 34),
            ansi256: 3,
            ansi16: AnsiColors::Yellow,
        },
        Role::Danger => ColorSpec {
            truecolor: (248, 81, 73),
            ansi256: 9,
            ansi16: AnsiColors::BrightRed,
        },
        Role::EffortLow => ColorSpec {
            truecolor: (88, 166, 255),
            ansi256: 12,
            ansi16: AnsiColors::BrightBlue,
        },
        Role::Model => ColorSpec {
            truecolor: (86, 182, 194),
            ansi256: 6,
            ansi16: AnsiColors::Cyan,
        },
        Role::Path => ColorSpec {
            truecolor: (255, 121, 198),
            ansi256: 13,
            ansi16: AnsiColors::BrightMagenta,
        },
        // No legacy equivalent: keep the original script's exact xterm-256 indices.
        Role::EffortHigh => ColorSpec {
            truecolor: (255, 140, 0),
            ansi256: 208,
            ansi16: AnsiColors::Yellow,
        },
        Role::Muted => ColorSpec {
            truecolor: (139, 148, 158),
            ansi256: 244,
            ansi16: AnsiColors::BrightBlack,
        },
    }
}

/// Renders `text` in the given semantic `role`, at the given `tier`,
/// optionally bold. Never emits escape codes at [`Tier::Plain`].
pub fn role(tier: Tier, role: Role, bold: bool, text: &str) -> String {
    let s = spec(role);
    match tier {
        Tier::Plain => text.to_string(),
        Tier::TrueColor => {
            let mut style = Style::new().color(Rgb(s.truecolor.0, s.truecolor.1, s.truecolor.2));
            if bold {
                style = style.bold();
            }
            text.style(style).to_string()
        }
        Tier::Ansi256 => {
            let prefix = if bold { "\x1b[1m" } else { "" };
            format!("{prefix}\x1b[38;5;{}m{text}\x1b[0m", s.ansi256)
        }
        Tier::Ansi16 => {
            let mut style = Style::new().color(s.ansi16);
            if bold {
                style = style.bold();
            }
            text.style(style).to_string()
        }
    }
}

/// Applies only the "dim" text effect, with no color; used for row labels'
/// bracket punctuation and separators, matching the original script's
/// color-agnostic `DIM` constant. A no-op at [`Tier::Plain`].
pub fn dim(tier: Tier, text: &str) -> String {
    match tier {
        Tier::Plain => text.to_string(),
        _ => format!("\x1b[2m{text}\x1b[0m"),
    }
}

/// Applies only the "bold" text effect, with no color. A no-op at [`Tier::Plain`].
pub fn bold(tier: Tier, text: &str) -> String {
    match tier {
        Tier::Plain => text.to_string(),
        _ => format!("\x1b[1m{text}\x1b[0m"),
    }
}
