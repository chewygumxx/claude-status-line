// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/format/time.rs
//
//

//! Reset-time and duration formatting.
//!
//! The original script formatted its compact reset time with
//! `strftime("%-I:%M")`. `%-I` is a glibc/BSD extension, not part of any
//! formatting standard, and isn't guaranteed to exist on every libc. Nothing
//! here uses a libc-style format string at all: the hour/minute/weekday are
//! read as plain integers/enum values from a parsed [`time::OffsetDateTime`]
//! and assembled with ordinary [`format!`], so there's no platform-specific
//! format directive to be missing in the first place.

use time::{OffsetDateTime, UtcOffset, Weekday};

/// Renders a rate-limit reset time compactly: `4:32p` if it falls within the
/// next 12 hours, `Fri 4:32p` otherwise. Returns an empty string for a
/// missing, zero, or unparseable epoch: the caller simply omits this part
/// of the row rather than showing an error.
///
/// An epoch within one UTC offset of the representable maximum is also
/// rendered as an empty string. Shifting such a timestamp into local time
/// carries it past `OffsetDateTime`'s year-9999 ceiling, and the unchecked
/// [`OffsetDateTime::to_offset`] panics rather than saturating. Omitting the
/// reset text is the same thing this function already does for every other
/// epoch it cannot make sense of, and it keeps
/// [`render`](crate::render)'s promise never to fail outright: a panic here
/// aborts the process and prints no status line at all.
pub fn fmt_reset(epoch: Option<i64>, now: OffsetDateTime) -> String {
    fmt_reset_at(epoch, now, local_offset())
}

/// [`fmt_reset`] with the UTC offset injected rather than read from the
/// environment.
///
/// The offset is a parameter purely so the boundary cases above are testable:
/// [`local_offset`] reports UTC under `cargo test`, for the reason documented
/// on it, and UTC is the one offset that can never push a representable
/// timestamp out of range.
fn fmt_reset_at(epoch: Option<i64>, now: OffsetDateTime, offset: UtcOffset) -> String {
    let Some(epoch) = epoch.filter(|&e| e != 0) else {
        return String::new();
    };
    let Ok(utc) = OffsetDateTime::from_unix_timestamp(epoch) else {
        return String::new();
    };
    let Some(dt) = utc.checked_to_offset(offset) else {
        return String::new();
    };
    let delta_s = epoch - now.unix_timestamp();

    let hour12 = match dt.hour() % 12 {
        0 => 12,
        h => h,
    };
    let suffix = if dt.hour() < 12 { 'a' } else { 'p' };
    let compact = format!("{hour12}:{:02}{suffix}", dt.minute());

    if (0..12 * 3600).contains(&delta_s) {
        compact
    } else {
        format!("{} {compact}", weekday_abbr(dt.weekday()))
    }
}

/// The local UTC offset, falling back to UTC if it can't be determined.
///
/// `time::UtcOffset::current_local_offset` refuses to run (returning `Err`)
/// when it can't prove the process is single-threaded, guarding against a
/// documented TOCTOU soundness issue in libc's `localtime`. This binary
/// never spawns threads, but rather than propagate that failure, falling
/// back to UTC keeps this function total, consistent with the rest of the
/// program never failing a render over a timezone lookup.
fn local_offset() -> UtcOffset {
    UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC)
}

fn weekday_abbr(w: Weekday) -> &'static str {
    match w {
        Weekday::Monday => "Mon",
        Weekday::Tuesday => "Tue",
        Weekday::Wednesday => "Wed",
        Weekday::Thursday => "Thu",
        Weekday::Friday => "Fri",
        Weekday::Saturday => "Sat",
        Weekday::Sunday => "Sun",
    }
}

/// Renders a session duration compactly: `45s`, `12m`, or `1h23m`. Returns
/// an empty string for a missing or non-positive duration.
pub fn fmt_duration(ms: Option<i64>) -> String {
    let Some(ms) = ms else {
        return String::new();
    };
    let total_s = ms / 1000;
    if total_s <= 0 {
        return String::new();
    }
    if total_s < 60 {
        return format!("{total_s}s");
    }
    let m = total_s / 60;
    if m < 60 {
        return format!("{m}m");
    }
    let (h, m) = (m / 60, m % 60);
    format!("{h}h{m:02}m")
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::datetime;

    #[test]
    fn missing_epoch_is_empty() {
        assert_eq!(fmt_reset(None, OffsetDateTime::now_utc()), "");
    }

    #[test]
    fn zero_epoch_is_empty() {
        assert_eq!(fmt_reset(Some(0), OffsetDateTime::now_utc()), "");
    }

    #[test]
    fn duration_seconds() {
        assert_eq!(fmt_duration(Some(45_000)), "45s");
    }

    #[test]
    fn duration_minutes() {
        assert_eq!(fmt_duration(Some(12 * 60_000)), "12m");
    }

    #[test]
    fn duration_hours_and_minutes() {
        assert_eq!(fmt_duration(Some((3600 + 23 * 60) * 1000)), "1h23m");
    }

    #[test]
    fn duration_zero_is_empty() {
        assert_eq!(fmt_duration(Some(0)), "");
    }

    #[test]
    fn duration_missing_is_empty() {
        assert_eq!(fmt_duration(None), "");
    }

    #[test]
    fn reset_within_twelve_hours_is_compact() {
        let now = datetime!(2026 - 08 - 31 12:00:00 UTC);
        let reset = datetime!(2026 - 08 - 31 16:32:00 UTC);
        let out = fmt_reset(Some(reset.unix_timestamp()), now);
        // Weekday-less form: no day abbreviation prefix.
        assert!(!out.contains(' '), "expected compact form, got {out:?}");
    }

    /// The largest and smallest epochs `OffsetDateTime::from_unix_timestamp`
    /// accepts: 9999-12-31T23:59:59Z and -9999-01-01T00:00:00Z.
    const EPOCH_MAX: i64 = 253_402_300_799;
    const EPOCH_MIN: i64 = -377_705_116_800;

    #[test]
    fn reset_at_the_maximum_epoch_renders_in_utc() {
        let now = datetime!(2026 - 08 - 31 12:00:00 UTC);
        let out = fmt_reset_at(Some(EPOCH_MAX), now, UtcOffset::UTC);
        assert_eq!(out, "Fri 11:59p");
    }

    /// Shifting the maximum epoch east carries it past year 9999, which
    /// `to_offset` answers with a panic. Rendering nothing is the same
    /// response this gives every other unusable epoch.
    #[test]
    fn reset_past_the_maximum_epoch_is_empty() {
        let now = datetime!(2026 - 08 - 31 12:00:00 UTC);
        let east = UtcOffset::from_hms(10, 0, 0).unwrap();
        assert_eq!(fmt_reset_at(Some(EPOCH_MAX), now, east), "");
        // One offset's worth below the ceiling is the widest window in which
        // this can happen, and the far edge of it still renders.
        let inside = EPOCH_MAX - 10 * 3600;
        assert_ne!(fmt_reset_at(Some(inside), now, east), "");
    }

    /// The same overflow in the other direction: the minimum epoch shifted
    /// west falls off the year -9999 floor.
    #[test]
    fn reset_before_the_minimum_epoch_is_empty() {
        let now = datetime!(2026 - 08 - 31 12:00:00 UTC);
        let west = UtcOffset::from_hms(-10, 0, 0).unwrap();
        assert_eq!(fmt_reset_at(Some(EPOCH_MIN), now, west), "");
        assert_ne!(fmt_reset_at(Some(EPOCH_MIN), now, UtcOffset::UTC), "");
    }

    /// An epoch outside the representable range never reaches the offset
    /// shift at all: `from_unix_timestamp` rejects it first.
    #[test]
    fn reset_outside_the_representable_range_is_empty() {
        let now = datetime!(2026 - 08 - 31 12:00:00 UTC);
        assert_eq!(fmt_reset_at(Some(EPOCH_MAX + 1), now, UtcOffset::UTC), "");
        assert_eq!(fmt_reset_at(Some(EPOCH_MIN - 1), now, UtcOffset::UTC), "");
        assert_eq!(fmt_reset_at(Some(i64::MAX), now, UtcOffset::UTC), "");
        assert_eq!(fmt_reset_at(Some(i64::MIN), now, UtcOffset::UTC), "");
    }

    #[test]
    fn reset_beyond_twelve_hours_includes_weekday() {
        let now = datetime!(2026 - 08 - 31 12:00:00 UTC);
        let reset = datetime!(2026 - 09 - 02 16:32:00 UTC);
        let out = fmt_reset(Some(reset.unix_timestamp()), now);
        assert!(
            out.contains(' '),
            "expected weekday-prefixed form, got {out:?}"
        );
    }
}
