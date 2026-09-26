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


# ---------------------------------------------------------------------------
# paths: port of `src/paths.rs`
# ---------------------------------------------------------------------------

# Strips leading and trailing whitespace from `$1`.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    R=${s%"${s##*[![:space:]]}"}
}

# Strips leading whitespace from `$1`.
trim_start() {
    local s=$1
    R=${s#"${s%%[![:space:]]*}"}
}

# Splits `$1` into `PATH_PARTS`, normalized the way Rust's `Path::components`
# normalizes: repeated separators collapse and `.` segments drop out, while
# `..` is left alone (`Path` resolves nothing on the filesystem, and neither
# does this). `PATH_ABS` records whether the path was absolute.
#
# Working in components rather than characters is the whole point of the Rust
# module this ports: a `startswith`-style comparison (which is what the original
# Python script did) treats `/home/chewygumxx` as living under `/home/chewygum`.
declare -a PATH_PARTS=()
PATH_ABS=0
path_split() {
    local path=$1 part
    PATH_PARTS=()
    if [ "${path:0:1}" = / ]; then PATH_ABS=1; else PATH_ABS=0; fi
    local -a raw=()
    # `read -ra` rather than unquoted word splitting: a path segment containing
    # a glob character must not be expanded against the filesystem.
    IFS='/' read -ra raw <<<"$path"
    for part in "${raw[@]}"; do
        case $part in
            ''|.) ;;
            *) PATH_PARTS+=("$part") ;;
        esac
    done
}

# Joins components `$@` into an absolute path string.
join_abs() {
    local IFS='/'
    R="/$*"
}

# The process's physical working directory, matching Rust's
# `std::env::current_dir` (which is `getcwd`, so symlinks are already resolved)
# rather than the logical `$PWD` bash inherits. `cd -P .` re-spells `PWD`
# physically without moving anywhere and without forking a subshell.
process_cwd() {
    builtin cd -P . 2>/dev/null
    R=$PWD
}

# Shortens `$1` to a leading `~` when it lies under the home directory,
# comparing components so a similarly-named sibling is left alone. A path that
# is not under home is returned exactly as given, unnormalized, which is what
# `Path::strip_prefix` failing leads to in the Rust version.
shorten_home() {
    local path=$1 home=${HOME-}
    R=$path
    [ -z "$home" ] && return

    local -a path_parts=() home_parts=()
    local path_abs
    path_split "$path"
    path_parts=("${PATH_PARTS[@]}")
    path_abs=$PATH_ABS
    path_split "$home"
    home_parts=("${PATH_PARTS[@]}")
    [ "$path_abs" = "$PATH_ABS" ] || return

    local count=${#home_parts[@]} i
    [ ${#path_parts[@]} -lt "$count" ] && return
    for ((i = 0; i < count; i++)); do
        [ "${path_parts[i]}" = "${home_parts[i]}" ] || return
    done

    if [ ${#path_parts[@]} -eq "$count" ]; then
        R='~'
        return
    fi
    local IFS='/'
    R="~/${path_parts[*]:count}"
}


# ---------------------------------------------------------------------------
# git: port of `src/git.rs`
# ---------------------------------------------------------------------------

# Deliberately subprocess-free, for the reason `src/git.rs` documents: this runs
# on every status-line render, and `.git/HEAD` plus `.git/config` answer the
# branch and origin questions directly. The one place the Rust program does
# shell out to `git` is the dirty/unpushed counter, ported in the next section.

GIT_ROOT=''
GIT_DIR=''
GIT_BRANCH=''
GIT_OWNER=''
GIT_REPO=''
GIT_REL_PATH=''

# Resolves a candidate `.git` path to the directory actually holding
# `HEAD`/`config`: `$1` itself when it is a directory, or the target of its
# `gitdir:` pointer when it is a file, which is the shape `.git` takes inside a
# worktree or a submodule.
resolve_git_dir() {
    local git_path=$1 contents target
    if [ -d "$git_path" ]; then
        R=$git_path
        return 0
    fi
    if [ -f "$git_path" ]; then
        contents=$(<"$git_path")
        trim "$contents"
        contents=$R
        case $contents in
            gitdir:*)
                trim "${contents#gitdir:}"
                target=$R
                if [ "${target:0:1}" != / ]; then
                    target="${git_path%/.git}/$target"
                fi
                R=$target
                return 0
                ;;
        esac
    fi
    R=''
    return 1
}

# Reads a branch name (or a short detached-HEAD hash) out of the `HEAD` file
# `$1`. Fails for a missing, empty, or whitespace-only file, matching the Rust
# version's refusal to return an empty branch that would render as a dangling
# separator.
read_head() {
    local head=$1 contents
    R=''
    [ -f "$head" ] || return 1
    contents=$(<"$head")
    trim "$contents"
    contents=$R
    case $contents in
        'ref: refs/heads/'*)
            R=${contents#ref: refs/heads/}
            ;;
        *)
            R=${contents:0:7}
            ;;
    esac
    [ -n "$R" ] || return 1
}

# Scans git config file `$1` for the `[remote "origin"]` section's `url`.
origin_url() {
    local file=$1 line section in_origin=0 rest
    R=''
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        trim "$line"
        line=$R
        case $line in
            '['*']')
                section=${line#[}
                section=${section%]}
                if [ "$section" = 'remote "origin"' ]; then
                    in_origin=1
                else
                    in_origin=0
                fi
                continue
                ;;
        esac
        [ "$in_origin" = 1 ] || continue
        case $line in
            url*)
                trim_start "${line#url}"
                rest=$R
                case $rest in
                    '='*)
                        trim "${rest#=}"
                        return 0
                        ;;
                esac
                ;;
        esac
    done <"$file"
    R=''
    return 1
}

# Extracts owner and repository name from remote URL `$1` into `GIT_OWNER` and
# `GIT_REPO`, handling scp-like (`git@host:owner/repo.git`), `https://`, and
# `ssh://` forms with or without the `.git` suffix.
parse_owner_repo() {
    local url rest head path owner repo
    trim "$1"
    url=$R
    rest=$url
    case $rest in *://*) rest=${rest#*://} ;; esac
    case $rest in *@*) rest=${rest#*@} ;; esac

    # The first `/` or `:`, whichever comes first, separates host from path.
    head=${rest%%[/:]*}
    [ "$head" = "$rest" ] && return 1
    path=${rest:${#head}+1}
    path=${path%.git}
    while [ "${path:0:1}" = / ]; do path=${path:1}; done
    while [ -n "$path" ] && [ "${path: -1}" = / ]; do path=${path%/}; done

    case $path in
        */*)
            owner=${path%/*}
            repo=${path##*/}
            ;;
        *) return 1 ;;
    esac
    if [ -z "$owner" ] || [ -z "$repo" ]; then
        return 1
    fi
    GIT_OWNER=$owner
    GIT_REPO=$repo
}

# Locates the repository containing `$1`, filling `GIT_ROOT`, `GIT_DIR`,
# `GIT_BRANCH`, `GIT_OWNER`, `GIT_REPO`, and `GIT_REL_PATH` (the path from the
# repository root to `$1`, `/`-separated, empty at the root itself). Fails when
# `$1` is not inside a repository.
#
# `GIT_REL_PATH` falls out of the upward walk rather than being recomputed: the
# components left over when the walk stops *are* the path relative to the root,
# so there is nothing for a second `strip_prefix` pass to discover.
git_locate() {
    local start=$1
    GIT_ROOT='' GIT_DIR='' GIT_BRANCH='' GIT_OWNER='' GIT_REPO='' GIT_REL_PATH=''

    if [ "${start:0:1}" != / ]; then
        process_cwd
        start="$R/$start"
    fi
    path_split "$start"

    local -a parts=("${PATH_PARTS[@]}")
    local -a rest=()
    local dir
    while :; do
        join_abs "${parts[@]}"
        dir=$R
        if resolve_git_dir "$dir/.git"; then
            GIT_DIR=$R
            GIT_ROOT=$dir
            break
        fi
        [ ${#parts[@]} -eq 0 ] && return 1
        rest=("${parts[@]: -1}" "${rest[@]}")
        unset "parts[${#parts[@]}-1]"
        parts=("${parts[@]}")
    done

    if [ ${#rest[@]} -gt 0 ]; then
        local IFS='/'
        GIT_REL_PATH="${rest[*]}"
    fi

    if read_head "$GIT_DIR/HEAD"; then
        GIT_BRANCH=$R
    fi
    if origin_url "$GIT_DIR/config"; then
        parse_owner_repo "$R" || true
    fi
    return 0
}
