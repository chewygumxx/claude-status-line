#!/usr/bin/env bash
# vim:set expandtab shiftwidth=4 filetype=bash:
# SPDX-License-Identifier: GPL-3.0-only
#
#
# ~chewygumxx/claude-status-line.git
# ::: :/claude-status-line.sh
#
#

# A bash port of this repository's Rust `claude-status-line` binary, intended
# as a drop-in stand-in on a machine where the Rust toolchain (or a built
# artifact) isn't available. Byte-for-byte output compatibility with the
# compiled binary is the whole point of this file: `tests/compare-with-rust.sh`
# diffs the two implementations over every fixture, every colour tier, and the
# edge cases enumerated in `.claude/reference/initial_errors.md`.
#
# Sections below mirror the Rust module they are ported from (`src/theme.rs`,
# `src/format/*.rs`, `src/git.rs`, and so on), in dependency order, so the two
# implementations can be read side by side. Divergences from the Rust program
# are deliberate, unavoidable, and commented individually; grep for
# "DIVERGENCE".
#
# Requires: bash 4+ (associative arrays), jq, GNU coreutils `date`, git.
#
# Note there is deliberately no `set -e` / `set -u` / `set -o pipefail` here.
# The Rust program never fails outright: a malformed payload, an unreadable
# settings file, or a missing `git` all degrade to a partially-filled status
# line rather than an error, on the grounds that a status line wrong in a few
# fields beats a crash that shows nothing. Aborting this script on the first
# non-zero exit status or unset variable would throw that property away.

# String-returning helpers below assign to the global `R` rather than writing
# to stdout for a caller to capture. A single render calls them upwards of
# fifty times, and `$(...)` would fork a subshell every time: the same
# fork-avoidance reasoning `src/git.rs` documents for not shelling out to
# `git` on the render hot path.
R=''

ESC=$'\033'


# ---------------------------------------------------------------------------
# theme: port of `src/theme.rs`
# ---------------------------------------------------------------------------

# The colour tier in use, one of `truecolor`, `ansi256`, `ansi16`, `plain`.
TIER='plain'

# Per-role colour values, transcribed from `spec()` in `src/theme.rs`. Three
# parallel arrays rather than one packed string per role, so a retint touches
# exactly one tier.
declare -A ROLE_TRUECOLOR=(
    [success]='63;185;80'
    [warning]='210;153;34'
    [danger]='248;81;73'
    [effort_low]='88;166;255'
    [effort_high]='255;140;0'
    [model]='86;182;194'
    [path]='164;48;255'
    [muted]='139;148;158'
    [owner]='95;149;250'
    [repo]='15;225;146'
    [path_marker]='232;224;255'
    [directory]='116;8;255'
    [branch]='127;197;223'
    [punctuation]='78;65;137'
    [divider]='202;214;255'
)

declare -A ROLE_ANSI256=(
    [success]=2
    [warning]=3
    [danger]=9
    [effort_low]=12
    [effort_high]=208
    [model]=6
    [path]=13
    [muted]=244
    [owner]=4
    [repo]=2
    [path_marker]=15
    [directory]=5
    [branch]=6
    [punctuation]=8
    [divider]=7
)

# SGR foreground codes matching `owo_colors::AnsiColors` at the ANSI16 tier.
declare -A ROLE_ANSI16=(
    [success]=32
    [warning]=33
    [danger]=91
    [effort_low]=94
    [effort_high]=33
    [model]=36
    [path]=95
    [muted]=90
    [owner]=34
    [repo]=32
    [path_marker]=97
    [directory]=35
    [branch]=36
    [punctuation]=90
    [divider]=37
)

# The process's environment as it was at exec time, keyed by variable name.
declare -A ENV_TRUE=()
ENV_TRUE_LOADED=0

# Loads `ENV_TRUE` from `/proc/self/environ`.
#
# DIVERGENCE (working around an injected variable, to *preserve* fidelity):
# bash sets a `TERM=dumb` shell variable of its own whenever `TERM` is absent
# from the environment. The Rust binary sees no `TERM` at all in that case,
# which is a different tier decision: `TERM=dumb` short-circuits to no colour,
# while an absent `TERM` falls through to the `COLORTERM`/`TERM_PROGRAM`/`CI`
# checks below. Reading the real environment instead of the shell's variables
# is what keeps "no TERM, but COLORTERM=truecolor" rendering in truecolour here
# exactly as it does under the binary.
#
# `/proc/self/environ` is Linux-only, matching this script's other GNU
# assumptions. Where it isn't readable, the shell's own variables are used as a
# fallback, which reintroduces the injected-`TERM` difference above in that one
# case only.
load_true_env() {
    ENV_TRUE=()
    local entry
    if [ -r /proc/self/environ ]; then
        # A pure-bash read: no `tr`/`xargs` fork, and no subshell that would
        # lose the array on exit.
        while IFS= read -r -d '' entry; do
            case $entry in
                *=*) ENV_TRUE[${entry%%=*}]=${entry#*=} ;;
            esac
        done < /proc/self/environ
        ENV_TRUE_LOADED=1
    fi
}

# True when environment variable `$1` was set (to any value, empty included).
env_is_set() {
    if [ "$ENV_TRUE_LOADED" = 1 ]; then
        [ -n "${ENV_TRUE[$1]+set}" ]
    else
        [ -n "${!1+set}" ]
    fi
}

# Assigns environment variable `$1`'s value to `R`, or the empty string when
# unset.
env_value() {
    if [ "$ENV_TRUE_LOADED" = 1 ]; then
        R=${ENV_TRUE[$1]-}
    else
        R=${!1-}
    fi
}

# The level `FORCE_COLOR` / `CLICOLOR_FORCE` force, or 0 for "not forced".
# Mirrors `supports-color`'s `env_force_color`, quirks included: `FORCE_COLOR`
# takes precedence over `CLICOLOR_FORCE` and suppresses it entirely, an
# unparseable value counts as 1 rather than as unset, and anything above 3 is
# capped at 3.
force_color_level() {
    local value
    if env_is_set FORCE_COLOR; then
        env_value FORCE_COLOR
        value=$R
        case $value in
            ''|true) R=1 ;;
            false) R=0 ;;
            # Anything that isn't a plain non-negative integer counts as 1,
            # matching `f.parse::<usize>().unwrap_or(1)`, so `-1` and `abc`
            # both force basic colour rather than being ignored.
            *[!0-9]*) R=1 ;;
            *) R=$(( value > 3 ? 3 : value )) ;;
        esac
        return
    fi
    if env_is_set CLICOLOR_FORCE; then
        env_value CLICOLOR_FORCE
        if [ "$R" != 0 ]; then R=1; else R=0; fi
        return
    fi
    R=0
}

# Detects the colour tier, reproducing `supports-color` 3.0.2's decision order
# as the Rust program experiences it.
#
# `src/theme.rs::detect_tier` sets `IGNORE_IS_TERMINAL`, deliberately opting out
# of the "stdout must be a tty" test, because this program's stdout is always
# captured by Claude Code rather than written to a terminal. There is therefore
# no tty check to port here at all: colour depends only on the environment.
#
# Every rule below (the suffix matches especially) was verified against the
# compiled binary rather than taken from the crate's documentation: the `TERM`
# tests are suffix matches, not substring ones, so `xterm-256color-foo` gets 16
# colours while a bare `256color` gets 256.
detect_tier() {
    load_true_env

    force_color_level
    local forced=$R
    if [ "$forced" -gt 0 ]; then
        case $forced in
            3) TIER='truecolor' ;;
            2) TIER='ansi256' ;;
            *) TIER='ansi16' ;;
        esac
        return
    fi

    if env_is_set NO_COLOR; then
        env_value NO_COLOR
        if [ "$R" != 0 ]; then
            TIER='plain'
            return
        fi
    fi

    local term colorterm program ci
    env_value TERM && term=$R
    env_value COLORTERM && colorterm=$R
    env_value TERM_PROGRAM && program=$R
    env_value CI && ci=$R

    if [ "$term" = dumb ]; then
        TIER='plain'
        return
    fi

    if [ "$colorterm" = truecolor ] || [ "$colorterm" = 24bit ] \
        || [ "$term" != "${term%direct}" ] || [ "$term" != "${term%truecolor}" ] \
        || [ "$program" = iTerm.app ]; then
        TIER='truecolor'
        return
    fi

    if [ "$term" != "${term%256color}" ] || [ "$program" = Apple_Terminal ]; then
        TIER='ansi256'
        return
    fi

    # `TERM` and `COLORTERM` count as soon as they are set, even to an empty
    # value, whereas `CI` has to be non-empty: an asymmetry in the crate,
    # preserved here.
    if env_is_set TERM || env_is_set COLORTERM || [ -n "$ci" ]; then
        TIER='ansi16'
        return
    fi

    TIER='plain'
}

# Renders `$3` in semantic role `$1`, bold when `$2` is 1. The bold form is
# tier-specific in shape, not just in colour: truecolor folds `1` into the
# colour SGR, ANSI256 emits a separate leading `\e[1m`, ANSI16 appends `;1`.
# That is what `owo-colors` produces for each tier, so it is what this has to
# produce too.
role() {
    local name=$1 bold=$2 text=$3
    case $TIER in
        plain)
            R=$text
            ;;
        truecolor)
            local suffix=''
            [ "$bold" = 1 ] && suffix=';1'
            R="${ESC}[38;2;${ROLE_TRUECOLOR[$name]}${suffix}m${text}${ESC}[0m"
            ;;
        ansi256)
            local prefix=''
            [ "$bold" = 1 ] && prefix="${ESC}[1m"
            R="${prefix}${ESC}[38;5;${ROLE_ANSI256[$name]}m${text}${ESC}[0m"
            ;;
        ansi16)
            local suffix=''
            [ "$bold" = 1 ] && suffix=';1'
            R="${ESC}[${ROLE_ANSI16[$name]}${suffix}m${text}${ESC}[0m"
            ;;
    esac
}

# The colour-agnostic "dim" effect used for bracket punctuation and separators.
dim() {
    if [ "$TIER" = plain ]; then
        R=$1
    else
        R="${ESC}[2m${1}${ESC}[0m"
    fi
}

# The colour-agnostic "bold" effect, used for the IN token total.
bold() {
    if [ "$TIER" = plain ]; then
        R=$1
    else
        R="${ESC}[1m${1}${ESC}[0m"
    fi
}


# ---------------------------------------------------------------------------
# format: port of `src/format/tokens.rs` and `src/format/time.rs`
#
# Percentage rounding and severity banding (`src/format/gauge.rs`) are not here:
# they happen inside this script's single `jq` call. `jq`'s `round` is C
# `round()`, that is half away from zero, which is exactly what Rust's
# `f64::round` does and exactly what bash arithmetic and `printf %.0f` (half to
# even) do not. Token compaction below stays in `printf` for the mirror-image
# reason: C `printf %.1f` rounds the binary value half to even, matching Rust's
# `{:.1}`, where `jq` has no equivalent formatter.
# ---------------------------------------------------------------------------

# Every token count is handled as a decimal *string*, never as a bash integer:
# the payload's counts are Rust `u64`s and bash arithmetic is signed 64-bit, so
# a legitimate count near `u64::MAX` would overflow into nonsense. Length
# comparisons and substring slicing have no such ceiling.

# Groups `$1`'s digits in threes, e.g. `13133` becomes `13,133`.
fmt_commas() {
    local digits=$1 out=''
    while [ ${#digits} -gt 3 ]; do
        out=",${digits: -3}$out"
        digits=${digits:0:${#digits}-3}
    done
    R="${digits}${out}"
}

# Divides `$1` by ten to the power `$2` by moving the decimal point, so the
# quotient keeps every digit instead of passing through a 64-bit division.
shift_decimal() {
    local digits=$1 places=$2
    while [ ${#digits} -le "$places" ]; do
        digits="0$digits"
    done
    R="${digits:0:${#digits}-places}.${digits: -places}"
}

# Formats a token count compactly: comma-grouped below 10,000, `12.3k` below
# 1,000,000, `1.2m` above. The thresholds are digit counts rather than numeric
# comparisons (see above): 5 digits is 10,000, 7 digits is 1,000,000.
fmt_compact() {
    local n=$1
    if [ ${#n} -ge 7 ]; then
        shift_decimal "$n" 6
        printf -v R '%.1fm' "$R"
    elif [ ${#n} -ge 5 ]; then
        shift_decimal "$n" 3
        printf -v R '%.1fk' "$R"
    else
        fmt_commas "$n"
    fi
}

# The bounds of `time::OffsetDateTime`, which spans years -9999 to 9999.
# `from_unix_timestamp` fails outside them, and `src/format/time.rs` renders an
# empty string for that failure.
EPOCH_MIN=-377705116800
EPOCH_MAX=253402300799

# Renders rate-limit reset epoch `$1`, relative to now (`$2`), as `4:32p`, or as
# `Fri 4:32p` when it does not fall within the next twelve hours. Empty for an
# absent, zero, or out-of-range epoch.
#
# The Rust version reads hour/minute/weekday as integers off a parsed
# `OffsetDateTime` specifically to avoid the non-portable `strftime("%-I")` the
# original Python script used. This port needs a `date` call, but it asks for
# `%H`/`%M`/`%a` and assembles the 12-hour clock itself, so there is still no
# `%-I` in play. `LC_ALL=C` keeps the weekday abbreviation English rather than
# locale-dependent, matching Rust's fixed `weekday_abbr` table.
fmt_reset() {
    local epoch=$1 now=$2
    R=''
    [ -z "$epoch" ] && return
    [ "$epoch" = 0 ] && return
    if [ "$epoch" -lt "$EPOCH_MIN" ] || [ "$epoch" -gt "$EPOCH_MAX" ]; then
        return
    fi

    local fields hour minute weekday
    fields=$(LC_ALL=C date -d "@$epoch" '+%H %M %a' 2>/dev/null) || return
    read -r hour minute weekday <<<"$fields"
    [ -z "$hour" ] && return

    # `10#` forces base ten: `date`'s zero-padded `08` would otherwise be read
    # as an invalid octal literal.
    local h=$((10#$hour)) suffix='p'
    [ "$h" -lt 12 ] && suffix='a'
    local hour12=$((h % 12))
    [ "$hour12" = 0 ] && hour12=12

    local compact="${hour12}:${minute}${suffix}"
    local delta=$((epoch - now))
    if [ "$delta" -ge 0 ] && [ "$delta" -lt 43200 ]; then
        R=$compact
    else
        R="$weekday $compact"
    fi
}
