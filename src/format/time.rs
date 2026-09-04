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
pub fn fmt_reset(epoch: Option<i64>, now: OffsetDateTime) -> String {
    let Some(epoch) = epoch.filter(|&e| e != 0) else {
        return String::new();
    };
    let Ok(utc) = OffsetDateTime::from_unix_timestamp(epoch) else {
        return String::new();
    };
    let dt = utc.to_offset(local_offset());
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
