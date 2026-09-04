// vim:set expandtab shiftwidth=4 filetype=rust:
// SPDX-License-Identifier: GPL-3.0-only
//
//
// ~chewygumxx/claude-status-line.git
// ::: :/src/format/tokens.rs
//
//

//! Token-count formatting.

/// Formats a token count with thousands separators, e.g. `13,133`.
pub fn fmt_commas(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, ch) in digits.chars().rev().enumerate() {
        if i != 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out.chars().rev().collect()
}

/// Formats a token count compactly: commas below 10,000, otherwise `12.3k`
/// below 1,000,000, otherwise `1.2m`.
pub fn fmt_compact(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}m", n as f64 / 1_000_000.0)
    } else if n >= 10_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        fmt_commas(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commas_below_thousand() {
        assert_eq!(fmt_commas(949), "949");
    }

    #[test]
    fn commas_above_thousand() {
        assert_eq!(fmt_commas(13_133), "13,133");
    }

    #[test]
    fn commas_millions() {
        assert_eq!(fmt_commas(1_234_567), "1,234,567");
    }

    #[test]
    fn compact_below_ten_thousand_uses_commas() {
        assert_eq!(fmt_compact(9_999), "9,999");
    }

    #[test]
    fn compact_boundary_ten_thousand() {
        assert_eq!(fmt_compact(10_000), "10.0k");
    }

    #[test]
    fn compact_boundary_million() {
        assert_eq!(fmt_compact(1_000_000), "1.0m");
    }

    #[test]
    fn compact_typical_cache_value() {
        assert_eq!(fmt_compact(64_600), "64.6k");
    }
}
