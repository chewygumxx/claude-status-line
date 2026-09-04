// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/format/gauge.rs
//
//

//! A single source of truth for percentage display and severity color.
//!
//! The original script computed the displayed percentage (rounded) and its
//! color (thresholded on the *unrounded* value) from the same raw number in
//! two separate, independently-error-handled functions, which could
//! disagree at rounding boundaries (a raw `79.6%` displayed as `"80%"` but
//! colored as if still under 80) and, worse, disagreed on how defensively
//! they parsed a malformed value. [`Gauge::from_percentage`] computes both
//! from one rounded value, so they can never do either.

use crate::theme::Role;

/// A percentage's severity band.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Low,
    Medium,
    High,
    /// No valid percentage was available.
    Unknown,
}

impl Severity {
    /// The color role this severity should render as.
    pub fn role(self) -> Role {
        match self {
            Severity::Low => Role::Success,
            Severity::Medium => Role::Warning,
            Severity::High => Role::Danger,
            Severity::Unknown => Role::Muted,
        }
    }
}

/// A rounded, ready-to-render percentage and its matching severity.
#[derive(Debug, Clone, Copy)]
pub struct Gauge {
    /// The rounded integer percentage to display, or `None` if unavailable.
    pub display: Option<u8>,
    pub severity: Severity,
}

impl Gauge {
    /// Builds a [`Gauge`] from a raw (possibly absent, possibly out-of-range,
    /// possibly non-finite) percentage. Never panics: `NaN`, infinities, and
    /// values outside `0..=255` all degrade to `display: None` rather than a
    /// failed cast.
    pub fn from_percentage(raw: Option<f64>) -> Self {
        let Some(value) = raw.filter(|v| v.is_finite()) else {
            return Gauge {
                display: None,
                severity: Severity::Unknown,
            };
        };
        let rounded = value.round();
        let display = if (0.0..=u8::MAX as f64).contains(&rounded) {
            Some(rounded as u8)
        } else {
            None
        };
        let severity = match display {
            Some(d) if d < 50 => Severity::Low,
            Some(d) if d < 80 => Severity::Medium,
            Some(_) => Severity::High,
            None => Severity::Unknown,
        };
        Gauge { display, severity }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_percentage_is_unknown() {
        let g = Gauge::from_percentage(None);
        assert_eq!(g.display, None);
        assert_eq!(g.severity, Severity::Unknown);
    }

    #[test]
    fn nan_percentage_is_unknown_not_a_panic() {
        let g = Gauge::from_percentage(Some(f64::NAN));
        assert_eq!(g.display, None);
        assert_eq!(g.severity, Severity::Unknown);
    }

    #[test]
    fn display_and_severity_agree_at_boundary() {
        // 79.6 previously displayed "80%" but colored as < 80 (yellow).
        // Severity must now be derived from the same rounded value shown.
        let g = Gauge::from_percentage(Some(79.6));
        assert_eq!(g.display, Some(80));
        assert_eq!(g.severity, Severity::High);
    }

    #[test]
    fn low_band() {
        assert_eq!(Gauge::from_percentage(Some(12.0)).severity, Severity::Low);
    }

    #[test]
    fn medium_band() {
        assert_eq!(
            Gauge::from_percentage(Some(65.0)).severity,
            Severity::Medium
        );
    }

    #[test]
    fn high_band() {
        assert_eq!(Gauge::from_percentage(Some(95.0)).severity, Severity::High);
    }
}
