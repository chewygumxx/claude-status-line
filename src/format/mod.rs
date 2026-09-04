// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/format/mod.rs
//
//

//! Pure, colorless value-formatting helpers, grouped by concern.
//!
//! Nothing in this module (or its children) touches ANSI escape codes:
//! that's [`crate::theme`]'s job. Keeping formatting and coloring separate
//! is what makes each independently unit-testable.

pub mod gauge;
pub mod time;
pub mod tokens;
