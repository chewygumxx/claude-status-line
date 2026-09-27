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

# Every variable `is_ci` treats as proof of a CI environment purely by being
# set, to any value at all, empty included. Transcribed from `is_ci` 1.2.0, the
# version `supports-color` 3.0.2 pulls in; the order is the crate's own, though
# nothing observes it. Note `GITHUB_ACTION`, singular: the per-step action id
# GitHub Actions sets, not the `GITHUB_ACTIONS` flag everyone reaches for.
IS_CI_PRESENT=(
    CI_NAME GITHUB_ACTION GITLAB_CI NETLIFY TRAVIS
    CODEBUILD_SRC_DIR BUILDER_OUTPUT GITLAB_DEPLOYMENT NOW_GITHUB_DEPLOYMENT
    NOW_BUILDER BITBUCKET_DEPLOYMENT GERRIT_PROJECT
    SYSTEM_TEAMFOUNDATIONCOLLECTIONURI BITRISE_IO BUDDY_WORKSPACE_ID BUILDKITE
    CIRRUS_CI APPVEYOR CIRCLECI SEMAPHORE DRONE DSARI TDDIUM STRIDER
    TASKCLUSTER_ROOT_URL JENKINS_URL bamboo.buildKey GO_PIPELINE_NAME
    HUDSON_URL WERCKER MAGNUM NEVERCODE RENDER SAIL_CI SHIPPABLE
)

# True when `is_ci::uncached()` would be true.
#
# `CI` is the odd one out: it counts only when it holds one of three exact
# values, so `CI=yes` and `CI=` are both *not* a CI environment as far as the
# crate is concerned, while a bare `JENKINS_URL=` is.
is_ci() {
    local name
    env_value CI
    case $R in
        true | 1 | woodpecker) return 0 ;;
    esac
    for name in "${IS_CI_PRESENT[@]}"; do
        env_is_set "$name" && return 0
    done
    # The single entry keyed on a value rather than on presence: Heroku's build
    # image. The doubled slash is the crate's, not a typo here, and it makes
    # the test rather harder to satisfy by accident than it looks.
    env_value NODE
    case $R in
        *//heroku/node/bin/node) return 0 ;;
    esac
    return 1
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

    local term colorterm program
    env_value TERM && term=$R
    env_value COLORTERM && colorterm=$R
    env_value TERM_PROGRAM && program=$R

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
    # value (a bare `TERM=` reaches here only because `TERM=dumb` returned
    # above, which is exactly what the crate's `check_ansi_color` works out
    # to). `CLICOLOR` counts unless it is the string `0`. `CI` gets the crate's
    # own rules, which are not a presence test: see `is_ci` above.
    local clicolor=0
    if env_is_set CLICOLOR; then
        env_value CLICOLOR
        [ "$R" != 0 ] && clicolor=1
    fi
    if env_is_set TERM || env_is_set COLORTERM || [ "$clicolor" = 1 ] || is_ci; then
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
#
# The bounds are checked twice, once before the local offset is applied and
# once after, because `checked_to_offset` can fail where
# `from_unix_timestamp` succeeded: an epoch within one offset of the ceiling
# is representable in UTC and not representable an hour east of it.
EPOCH_MIN=-377705116800
EPOCH_MAX=253402300799

# The current UTC offset in seconds, resolved once per run, matching Rust's
# single `UtcOffset::current_local_offset()` lookup. Falls back to UTC, as
# `local_offset()` does when the offset cannot be determined.
LOCAL_OFFSET_SECONDS=''
local_offset_seconds() {
    if [ -z "$LOCAL_OFFSET_SECONDS" ]; then
        local z sign hours minutes
        z=$(date +%z 2>/dev/null)
        case $z in
            [-+][0-9][0-9][0-9][0-9])
                sign=${z:0:1}
                hours=$((10#${z:1:2}))
                minutes=$((10#${z:3:2}))
                LOCAL_OFFSET_SECONDS=$((hours * 3600 + minutes * 60))
                [ "$sign" = - ] && LOCAL_OFFSET_SECONDS=$((-LOCAL_OFFSET_SECONDS))
                ;;
            *) LOCAL_OFFSET_SECONDS=0 ;;
        esac
    fi
    R=$LOCAL_OFFSET_SECONDS
}

# Renders rate-limit reset epoch `$1`, relative to now (`$2`), as `4:32p`, or as
# `Fri 4:32p` when it does not fall within the next twelve hours. Empty for an
# absent, zero, or out-of-range epoch.
#
# The Rust version reads hour/minute/weekday as integers off a parsed
# `OffsetDateTime`, specifically to avoid the non-portable `strftime("%-I")` the
# original Python script used, and this does the same with shell arithmetic
# rather than by shelling out. Only three numbers are wanted from the
# timestamp, and none of them needs the calendar: time of day is the remainder
# modulo a day, and the weekday is the day count modulo seven. Calling `date`
# for that would cost a fork, tie the script to GNU `date`'s `-d @epoch`
# spelling (BSD and macOS want `-r`), and drag in a locale-dependent `%a` that
# would then need `LC_ALL=C` to match Rust's fixed `weekday_abbr` table.
WEEKDAY_ABBR=(Sun Mon Tue Wed Thu Fri Sat)
fmt_reset() {
    local epoch=$1 now=$2
    R=''
    [ -z "$epoch" ] && return
    [ "$epoch" = 0 ] && return
    if [ "$epoch" -lt "$EPOCH_MIN" ] || [ "$epoch" -gt "$EPOCH_MAX" ]; then
        return
    fi

    local_offset_seconds
    # Rust reads one offset (`UtcOffset::current_local_offset`, the offset right
    # now) and applies it to every timestamp, so a reset on the far side of a
    # daylight-saving boundary renders an hour off what a timezone-aware
    # conversion would say. Shifting the epoch and treating the result as UTC
    # reproduces that arithmetic rather than correcting it.
    #
    # `checked_to_offset`'s failure case follows: representable before the
    # shift, off the end of the calendar after it. `R` carries the offset in at
    # this point, so it has to go back to the empty return value before any
    # early exit, or the offset itself ends up rendered as the reset time.
    local shifted=$((epoch + R))
    R=''
    if [ "$shifted" -lt "$EPOCH_MIN" ] || [ "$shifted" -gt "$EPOCH_MAX" ]; then
        return
    fi

    # Bash's `/` and `%` truncate toward zero, so a pre-1970 timestamp needs
    # nudging back onto a floored division before the remainder means "seconds
    # into the day".
    local days=$((shifted / 86400)) secs=$((shifted % 86400))
    if [ "$secs" -lt 0 ]; then
        secs=$((secs + 86400))
        days=$((days - 1))
    fi

    local h=$((secs / 3600)) suffix='p'
    [ "$h" -lt 12 ] && suffix='a'
    local hour12=$((h % 12))
    [ "$hour12" = 0 ] && hour12=12
    local minute
    printf -v minute '%02d' $((secs / 60 % 60))

    # 1970-01-01 was a Thursday, which is index 4 of the table above. The extra
    # `+ 7` keeps the result non-negative for dates before it.
    local weekday=${WEEKDAY_ABBR[((days + 4) % 7 + 7) % 7]}

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
# does this). `PATH_ABS` records whether the path was absolute, and `PATH_ENDS`
# the offset just past each component in the original string.
#
# Working in components rather than characters is the whole point of the Rust
# module this ports: a `startswith`-style comparison (which is what the original
# Python script did) treats `/home/chewygumxx` as living under `/home/chewygum`.
#
# `PATH_ENDS` exists because comparison and *display* need different strings.
# Rust compares components but renders `Components::as_path()`, the raw
# remaining slice, which only has its ends tidied: interior `//` and `/./`
# survive into the output, so `~/a//b` and `:/a/./b` are what the binary really
# prints. Recording offsets lets this port slice the same raw remainder rather
# than rendering a normalized path the binary would not have produced.
declare -a PATH_PARTS=()
declare -a PATH_ENDS=()
PATH_ABS=0
path_split() {
    local path=$1 part start i=0 n=${#1}
    PATH_PARTS=()
    PATH_ENDS=()
    if [ "${path:0:1}" = / ]; then PATH_ABS=1; else PATH_ABS=0; fi
    while [ "$i" -lt "$n" ]; do
        while [ "$i" -lt "$n" ] && [ "${path:i:1}" = / ]; do
            i=$((i + 1))
        done
        start=$i
        while [ "$i" -lt "$n" ] && [ "${path:i:1}" != / ]; do
            i=$((i + 1))
        done
        part=${path:start:i-start}
        case $part in
            ''|.) ;;
            *)
                PATH_PARTS+=("$part")
                PATH_ENDS+=("$i")
                ;;
        esac
    done
}

# Trims `$1` the way `Components::as_path` does: leading and trailing separators
# and `.` components go, everything in the middle is left exactly as written.
trim_path_ends() {
    local s=$1
    while :; do
        case $s in
            /*) s=${s#/} ;;
            ./*) s=${s#./} ;;
            .) s='' ;;
            *) break ;;
        esac
    done
    while :; do
        case $s in
            */) s=${s%/} ;;
            */.) s=${s%/.} ;;
            *) break ;;
        esac
    done
    R=$s
}

# The process's physical working directory, matching Rust's
# `std::env::current_dir` (which is `getcwd`, so symlinks are already resolved)
# rather than the logical `$PWD` bash inherits. `cd -P .` re-spells `PWD`
# physically without moving anywhere and without forking a subshell.
process_cwd() {
    # shellcheck disable=SC2164 # a failed `cd .` leaves `$PWD` usable as-is,
    # and aborting the render over it would be worse than a logical path
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

    local -a path_parts=() path_ends=() home_parts=()
    local path_abs
    path_split "$path"
    path_parts=("${PATH_PARTS[@]}")
    path_ends=("${PATH_ENDS[@]}")
    path_abs=$PATH_ABS
    path_split "$home"
    home_parts=("${PATH_PARTS[@]}")
    [ "$path_abs" = "$PATH_ABS" ] || return

    local count=${#home_parts[@]} i
    [ ${#path_parts[@]} -lt "$count" ] && return
    for ((i = 0; i < count; i++)); do
        [ "${path_parts[i]}" = "${home_parts[i]}" ] || return
    done

    # The remainder is sliced out of the original string, not rebuilt from
    # components, so an interior `//` renders as the binary renders it.
    local tail=$path
    [ "$count" -gt 0 ] && tail=${path:path_ends[count-1]}
    trim_path_ends "$tail"
    if [ -z "$R" ]; then
        R='~'
    else
        # shellcheck disable=SC2088 # a literal tilde is the point: this is
        # display text, not a path to be resolved
        R="~/$R"
    fi
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

    # The walk shortens a prefix of the original string rather than rebuilding
    # a path from components, mirroring `PathBuf::pop`: that is what makes
    # `GIT_ROOT` and the relative remainder below spell interior separators the
    # way the binary spells them.
    local -a ends=("${PATH_ENDS[@]}")
    local depth=${#PATH_PARTS[@]} dir
    while :; do
        if [ "$depth" -eq 0 ]; then
            dir='/'
        else
            dir=${start:0:ends[depth-1]}
        fi
        if resolve_git_dir "$dir/.git"; then
            GIT_DIR=$R
            GIT_ROOT=$dir
            break
        fi
        [ "$depth" -eq 0 ] && return 1
        depth=$((depth - 1))
    done

    if [ "$depth" -gt 0 ]; then
        trim_path_ends "${start:ends[depth-1]}"
        GIT_REL_PATH=$R
    else
        trim_path_ends "$start"
        GIT_REL_PATH=$R
    fi

    if read_head "$GIT_DIR/HEAD"; then
        GIT_BRANCH=$R
    fi
    if origin_url "$GIT_DIR/config"; then
        parse_owner_repo "$R" || true
    fi
    return 0
}


# ---------------------------------------------------------------------------
# repo_status: port of `src/repo_status.rs`
#
# The one deliberate exception to the no-subprocess rule above, for the reason
# that module documents: there is no sane way to answer "how many tracked files
# are dirty" or "is HEAD ahead of the cached origin ref" without asking `git`.
# The ahead-check never touches the network; it compares against whatever
# `refs/remotes/origin/<branch>` currently says.
# ---------------------------------------------------------------------------

# Seconds a cached answer is reused before `git` is consulted again, matching
# `CACHE_TTL` in the Rust module and the interval in Claude Code's own
# documented example of this caching pattern.
REPO_STATUS_TTL=5

# Set by `repo_status_query`: whether a status could be determined at all, the
# dirty-file count, and whether HEAD is ahead of the cached origin ref.
STATUS_AVAILABLE=0
STATUS_DIRTY=0
STATUS_UNPUSHED=0

# The current time in whole seconds, without forking `date` where bash 5's
# `EPOCHSECONDS` is available.
now_seconds() {
    R=${EPOCHSECONDS:-$(date +%s)}
}

# A 64-bit FNV-1a hash of `$1`, in hex.
#
# DIVERGENCE: the Rust version hashes the repository root with
# `std::collections::hash_map::DefaultHasher` (SipHash-1-3), which cannot be
# reproduced here. The hash only has to be stable and collision-resistant enough
# to keep two repositories in one session apart, so any decent hash does the
# job; this one is a handful of shell arithmetic ops and, unlike `cksum`, costs
# no fork. Because the digest differs from Rust's, cache files are given a
# distinct name prefix below rather than being silently incompatible with the
# binary's.
fnv1a() {
    local text=$1 i char hash=14695981039346656037
    for ((i = 0; i < ${#text}; i++)); do
        char=${text:i:1}
        printf -v char '%d' "'$char"
        # Overflow wraps, which is exactly what a hash wants.
        hash=$(((hash ^ char) * 1099511628211))
    done
    printf -v R '%x' "$hash"
}

# The cache file for repository root `$1` in session `$2`.
#
# The session id comes out of an external JSON payload, so it is sanitized to a
# bare filename fragment rather than trusted, the same reasoning (and the same
# character class) as the Rust version's.
repo_status_cache_path() {
    local root=$1 session=$2 safe='' i char
    for ((i = 0; i < ${#session}; i++)); do
        char=${session:i:1}
        case $char in
            [A-Za-z0-9_-]) safe+=$char ;;
            *) safe+='_' ;;
        esac
    done
    fnv1a "$root"
    R="${TMPDIR:-/tmp}/claude-status-line-sh-repo-status-${safe}-${R}"
}

# Counts tracked files with staged and/or unstaged changes. `git status
# --porcelain` prints exactly one line per changed path, renames included,
# whether the change is staged, unstaged, or both. Fails when `git` cannot be
# run or exits non-zero, which is what makes the caller drop the counter
# entirely instead of showing a wrong one.
dirty_count() {
    local root=$1 out
    out=$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null) || return 1
    local -a lines=()
    mapfile -t lines <<<"$out"
    local count=0 line
    for line in "${lines[@]}"; do
        [ -n "$line" ] && count=$((count + 1))
    done
    R=$count
}

# True (exit 0) when HEAD holds commits the cached `origin/$2` does not, and
# also when that comparison cannot be made at all: a missing remote-tracking
# ref, no `origin`, an unborn HEAD, or a non-zero `git` exit all count as
# unpushed rather than quietly hiding the marker.
is_unpushed() {
    local root=$1 branch=$2 out
    out=$(git -C "$root" rev-list --count "origin/${branch}..HEAD" 2>/dev/null) || return 0
    trim "$out"
    case $R in
        ''|*[!0-9]*) return 0 ;;
    esac
    # A count that cannot fit in bash arithmetic is certainly greater than zero.
    [ ${#R} -gt 18 ] && return 0
    [ "$R" -gt 0 ]
}

# Queries the counter for repository root `$1` on branch `$2` (possibly empty),
# reusing a cached answer for session `$3` when one is fresh. An absent session
# id skips the cache entirely, matching the Rust version's `session_id: None`
# path.
repo_status_query() {
    local root=$1 branch=$2 session=$3
    STATUS_AVAILABLE=0 STATUS_DIRTY=0 STATUS_UNPUSHED=0

    local cache=''
    if [ -n "$session" ]; then
        repo_status_cache_path "$root" "$session"
        cache=$R
        if repo_status_read_cache "$cache"; then
            return 0
        fi
    fi

    if dirty_count "$root"; then
        STATUS_AVAILABLE=1
        STATUS_DIRTY=$R
        if [ -z "$branch" ] || is_unpushed "$root" "$branch"; then
            STATUS_UNPUSHED=1
        fi
    fi

    [ -n "$cache" ] && repo_status_write_cache "$cache"
    return 0
}

# Reads a cached answer from `$1`, succeeding only when the file exists, parses,
# and is younger than `REPO_STATUS_TTL`.
#
# DIVERGENCE: the Rust version takes the entry's age from the file's mtime.
# Recording the write time inside the file instead keeps this fork-free (no
# `stat`), which matters in the one code path whose entire purpose is to avoid
# process spawns. The cost is that the TTL is measured in whole seconds rather
# than with sub-second precision.
repo_status_read_cache() {
    local path=$1 contents written rest
    [ -f "$path" ] || return 1
    contents=$(<"$path")
    trim "$contents"
    contents=$R

    written=${contents%%|*}
    rest=${contents#*|}
    case $written in
        ''|*[!0-9-]*) return 1 ;;
    esac
    now_seconds
    [ $((R - written)) -gt "$REPO_STATUS_TTL" ] && return 1

    if [ "$rest" = NONE ]; then
        STATUS_AVAILABLE=0
        return 0
    fi
    local count=${rest%%|*} unpushed=${rest##*|}
    case $count in
        ''|*[!0-9]*) return 1 ;;
    esac
    STATUS_AVAILABLE=1
    STATUS_DIRTY=$count
    [ "$unpushed" = 1 ] && STATUS_UNPUSHED=1 || STATUS_UNPUSHED=0
    return 0
}

# Writes the current answer to `$1`. Best-effort: a read-only temp directory or
# a race with a concurrent render just means the next render asks `git` again.
repo_status_write_cache() {
    local path=$1 payload
    now_seconds
    if [ "$STATUS_AVAILABLE" = 1 ]; then
        payload="${R}|${STATUS_DIRTY}|${STATUS_UNPUSHED}"
    else
        payload="${R}|NONE"
    fi
    printf '%s' "$payload" >"$path" 2>/dev/null || true
}


# ---------------------------------------------------------------------------
# payload: port of `src/payload.rs` and `src/format/gauge.rs`
# ---------------------------------------------------------------------------

# Parsed payload fields, keyed by the names the `jq` program below emits.
declare -A P=()

# The `jq` program. It does three jobs that have to happen together:
#
#  1. Validates the payload against `src/payload.rs`'s schema, and substitutes
#     an empty object for the whole payload if anything fails. That looks
#     heavy-handed, and it is: `serde` gives up on the entire document over one
#     ill-typed field, so `{"model":{"display_name":"M"},"cost":{...:"x"}}`
#     renders no model name at all under the binary. Validating field by field
#     here would be *more* forgiving than the program being ported, which is
#     just as wrong as being less forgiving.
#  2. Distinguishes a missing key (fine: every leaf is an `Option`) from a
#     present but ill-typed one, and an explicit `null` at a leaf (fine) from an
#     explicit `null` where a nested struct belongs (not fine: `#[serde(default)]`
#     only covers absence).
#  3. Computes each percentage gauge, because `jq`'s `round` is C `round()`,
#     which breaks ties away from zero exactly as Rust's `f64::round` does.
#
# Type checks run against `tojson`, the number's *original literal*, not its
# parsed value: `serde` rejects `949.0` for a `u64` field, and a parsed double
# cannot tell that from `949`. The same trick keeps the `u64::MAX` bound exact,
# by comparing 20-digit literals as strings rather than as doubles.
# shellcheck disable=SC2016 # single quotes are deliberate: this is a jq program,
# and every `$name` in it is a jq variable, not a shell one
PAYLOAD_JQ='
def is_str: type == "string";
def is_f64: type == "number";
def is_u64:
    type == "number"
    and (tojson | test("^[0-9]+$"))
    and (tojson | length as $n | $n < 20 or ($n == 20 and . <= "18446744073709551615"));
def is_i64:
    type == "number"
    and (tojson | test("^-?[0-9]+$"))
    and (length <= 9223372036854775807);

# An absent key is always acceptable; a present one must be null or valid.
def leaf(name; f): if has(name) then (.[name] | . == null or f) else true end;
# A present nested struct must be an object: an explicit null is a serde error.
def nested(name; f): if has(name) then (.[name] | type == "object" and f) else true end;

def valid:
    type == "object"
    and leaf("cwd"; is_str)
    and leaf("session_id"; is_str)
    and nested("workspace"; leaf("current_dir"; is_str))
    and nested("model"; leaf("display_name"; is_str) and leaf("id"; is_str))
    and nested("effort"; leaf("level"; is_str))
    and nested("cost"; leaf("total_duration_ms"; is_i64))
    and nested("context_window";
        leaf("used_percentage"; is_f64)
        and leaf("total_input_tokens"; is_u64)
        and leaf("total_output_tokens"; is_u64)
        and nested("current_usage";
            leaf("input_tokens"; is_u64)
            and leaf("output_tokens"; is_u64)
            and leaf("cache_creation_input_tokens"; is_u64)
            and leaf("cache_read_input_tokens"; is_u64)))
    and nested("rate_limits";
        nested("five_hour"; leaf("used_percentage"; is_f64) and leaf("resets_at"; is_i64))
        and nested("seven_day"; leaf("used_percentage"; is_f64) and leaf("resets_at"; is_i64)));

# A rounded percentage and its severity role, or "?" / muted when unusable.
# Adding zero normalizes the -0.0 that rounding a small negative produces, which
# is in range (so it renders as 0%) but must not print as "-0".
def gauge:
    if type != "number" or isinfinite or isnan then
        {display: "?", role: "muted"}
    else
        (round) as $r
        | if $r >= 0 and $r <= 255 then
            ($r + 0) as $d
            | {display: ($d | tostring),
               role: (if $d < 50 then "success" elif $d < 80 then "warning" else "danger" end)}
          else
            {display: "?", role: "muted"}
          end
    end;

def count: if . == null then "0" else tojson end;
def epoch: if . == null then "" else tojson end;
def text: if . == null then "" else . end;
def emit(k; v): "\(k)=\(v)\u0000";

(if valid then . else {} end)
| (.context_window // {}) as $cw
| ($cw.current_usage // {}) as $cu
| (.rate_limits // {}) as $rl
| ($rl.five_hour // {}) as $five
| ($rl.seven_day // {}) as $seven
| ($cw.used_percentage | gauge) as $ctx
| ($five.used_percentage | gauge) as $fiveg
| ($seven.used_percentage | gauge) as $seveng
| emit("cwd"; .workspace.current_dir | text)
+ emit("cwd_fallback"; .cwd | text)
+ emit("model_name"; .model.display_name | text)
+ emit("model_id"; .model.id | text)
+ emit("effort"; .effort.level | text)
+ emit("session_id"; .session_id | text)
+ emit("total_in"; $cw.total_input_tokens | count)
+ emit("total_out"; $cw.total_output_tokens | count)
+ emit("turn_in"; $cu.input_tokens | count)
+ emit("turn_out"; $cu.output_tokens | count)
+ emit("cache_write"; $cu.cache_creation_input_tokens | count)
+ emit("cache_read"; $cu.cache_read_input_tokens | count)
+ emit("ctx_display"; $ctx.display)
+ emit("ctx_role"; $ctx.role)
+ emit("five_display"; $fiveg.display)
+ emit("five_role"; $fiveg.role)
+ emit("five_reset"; $five.resets_at | epoch)
+ emit("seven_display"; $seveng.display)
+ emit("seven_role"; $seveng.role)
+ emit("seven_reset"; $seven.resets_at | epoch)
'

# The field values a payload that parses to nothing produces, used when `jq` is
# absent or the payload is not JSON at all.
payload_defaults() {
    P=(
        [cwd]='' [cwd_fallback]='' [model_name]='' [model_id]='' [effort]=''
        [session_id]='' [total_in]=0 [total_out]=0 [turn_in]=0 [turn_out]=0
        [cache_write]=0 [cache_read]=0
        [ctx_display]='?' [ctx_role]=muted
        [five_display]='?' [five_role]=muted [five_reset]=''
        [seven_display]='?' [seven_role]=muted [seven_reset]=''
    )
}

# Parses raw payload `$1` into `P`.
#
# DIVERGENCE: the Rust binary is self-contained, where this needs `jq`. Rather
# than fail, a missing `jq` degrades to the same output an unparseable payload
# gives, consistent with the program's "a degraded status line beats no status
# line" stance.
payload_parse() {
    local raw=$1 entry key
    payload_defaults
    command -v jq >/dev/null 2>&1 || return 0

    # `< <(...)` rather than a pipe: a pipeline would run this loop in a
    # subshell and `P` would be discarded when it exited.
    while IFS= read -r -d '' entry; do
        key=${entry%%=*}
        P[$key]=${entry#*=}
    done < <(printf '%s' "$raw" | jq -j -r "$PAYLOAD_JQ" 2>/dev/null)
}


# ---------------------------------------------------------------------------
# config: port of `src/config.rs`
# ---------------------------------------------------------------------------

# The settings cascade, consulted only when the payload carries no
# `effort.level`: project-local overrides beat the committed project file, which
# beats the user-wide one.
settings_candidates() {
    local cwd=$1
    SETTINGS_FILES=("$cwd/.claude/settings.local.json" "$cwd/.claude/settings.json")
    # `dirs::home_dir()` is `$HOME` here, so this deliberately reads
    # `~/.claude/settings.json` and not `$CLAUDE_CONFIG_DIR`, exactly as the
    # Rust version does.
    [ -n "${HOME-}" ] && SETTINGS_FILES+=("$HOME/.claude/settings.json")
}
declare -a SETTINGS_FILES=()

# Merges the cascade and resolves the effort level for model id `$2`, searching
# `modelSettings.<id>.effortLevel` before the top-level `effortLevel` default.
#
# The merge keeps the first *truthy* value for each leaf rather than the first
# present one, and descends into nested objects, so a higher-priority file that
# sets `effortLevel` to `""` (or merely mentions the model under
# `modelSettings`) does not shadow a real value further down. That is the
# original Python script's `if v: return v` behaviour, generalized per leaf.
settings_effort_level() {
    local cwd=$1 model_id=$2
    R=''
    command -v jq >/dev/null 2>&1 || return 0

    settings_candidates "$cwd"
    local -a args=()
    local file i contents
    # Always three `--arg`s, even when `$HOME` is unset and there are only two
    # candidate files: `jq` fails on a reference to an undefined variable.
    for ((i = 0; i < 3; i++)); do
        contents=''
        file=${SETTINGS_FILES[i]-}
        # Files are read here rather than by `jq` so that an unreadable one is
        # skipped as silently as a malformed one.
        [ -n "$file" ] && [ -r "$file" ] && contents=$(<"$file")
        args+=(--arg "s$i" "$contents")
    done

    R=$(jq -n -r --arg model "$model_id" "${args[@]}" '
        def truthy: . != null and . != false and . != "" and . != 0 and . != [] and . != {};
        def parsed: if . == "" then null else (try fromjson catch null) end
            | if type == "object" then . else null end;
        def mergeinto($inc):
            reduce ($inc | keys_unsorted[]) as $k (.;
                if (has($k) | not) then
                    .[$k] = $inc[$k]
                elif (.[$k] | type == "object") and ($inc[$k] | type == "object") then
                    .[$k] |= mergeinto($inc[$k])
                elif (.[$k] | truthy) then
                    .
                elif ($inc[$k] | truthy) then
                    .[$k] = $inc[$k]
                else
                    .
                end);
        [$s0, $s1, $s2] | map(parsed) | map(select(. != null)) as $files
        | reduce $files[] as $f ({}; mergeinto($f))
        # Each step checks the type before descending: Rust reaches these
        # through `Value::get`, which returns `None` rather than failing when
        # the value in the way is not an object.
        | ((.modelSettings | if type == "object" then .[$model] else null end
            | if type == "object" then .effortLevel else null end)) as $per_model
        | if ($per_model | type) == "string" then $per_model
          elif (.effortLevel | type) == "string" then .effortLevel
          else "" end
    ' 2>/dev/null) || R=''
}


# ---------------------------------------------------------------------------
# render: port of `src/render.rs`
#
# Both row assembly and the two shared primitives live here, `bracketed` and
# `separator`, so that (as that module's comment puts it) there is exactly one
# implementation of "put dim brackets around this" to maintain rather than the
# two byte-identical copies the original Python script accumulated.
# ---------------------------------------------------------------------------

# Wraps `$1` in dim brackets.
bracketed() {
    local inner=$1 open close
    dim '['
    open=$R
    dim ']'
    close=$R
    R="${open}${inner}${close}"
}

# The dim ` · ` separator between row fields (U+00B7).
separator() {
    dim $' · '
}

# One bracketed usage gauge: label, percentage, and optional reset time.
gauge_field() {
    local label=$1 display=$2 severity=$3 reset=$4 inner pct_text
    if [ "$display" = '?' ]; then
        pct_text='?'
    else
        pct_text="${display}%"
    fi
    role muted 0 "$label"
    inner=$R
    role "$severity" 1 "$pct_text"
    inner+=" $R"
    if [ -n "$reset" ]; then
        role muted 0 "$reset"
        inner+=" $R"
    fi
    bracketed "$inner"
}

# Row: context-window, five-hour, and seven-day usage gauges.
row_limits() {
    local out
    gauge_field CTX "${P[ctx_display]}" "${P[ctx_role]}" ''
    out=$R
    gauge_field 5H "${P[five_display]}" "${P[five_role]}" "$FIVE_RESET"
    out+=" $R"
    gauge_field 7D "${P[seven_display]}" "${P[seven_role]}" "$SEVEN_RESET"
    R="$out $R"
}

# The ` +N` per-turn delta, empty when the turn contributed nothing.
delta() {
    local n=$1
    R=''
    [ "$n" = 0 ] && return
    fmt_commas "$n"
    role muted 0 "+$R"
    R=" $R"
}

# One bracketed `<label><value>` field.
labeled_field() {
    local label=$1 value=$2
    role muted 0 "$label"
    bracketed "${R}${value}"
}

# Row: input and output totals with per-turn deltas, plus cache usage.
row_tokens() {
    local out value

    fmt_compact "${P[total_in]}"
    bold "$R"
    value=$R
    delta "${P[turn_in]}"
    value+="$R"
    labeled_field 'IN ' "$value"
    out=$R

    fmt_compact "${P[total_out]}"
    role danger 1 "$R"
    value=$R
    delta "${P[turn_out]}"
    value+="$R"
    labeled_field 'OUT ' "$value"
    out+=" $R"

    value=''
    if [ "${P[cache_write]}" != 0 ]; then
        fmt_compact "${P[cache_write]}"
        role warning 0 "+$R"
        value=$R
        dim ' / '
        value+="$R"
    fi
    fmt_compact "${P[cache_read]}"
    role success 0 "$R"
    value+="$R"
    labeled_field 'CACHE ' "$value"
    R="$out $R"
}

# The colour role for an effort level.
effort_role() {
    case $1 in
        LOW) R=effort_low ;;
        MEDIUM) R=warning ;;
        HIGH) R=effort_high ;;
        MAX) R=danger ;;
        *) R=muted ;;
    esac
}

# Row: model name and effort level, joined by a plain space. The dim separator
# that follows is appended by `render_payload`, not here.
row_config() {
    local model=$1 effort=$2 out
    role model 0 "$model"
    out=$R
    effort_role "$effort"
    role "$R" 1 "$effort"
    R="$out $R"
}

# Row: the home-shortened working directory, when not inside a repository.
row_where_pwd() {
    shorten_home "$1"
    role path 0 "$R"
}

# Row: `[!]<count> <branch> ~<owner>/<repo>.git:/<path>` inside a repository.
#
# The branch is shown for every branch it can resolve, `main` included, and the
# `:/` marker is always shown, bold when the working directory *is* the
# repository root. The counter is omitted when there is nothing to report.
# Per-token colours follow `.claude/reference/where_row_colors.md`.
row_where_repo() {
    local branch=$1 owner=$2 repo=$3 rel=$4 has_counter=$5 count=$6 unpushed=$7
    local out='' severity text

    if [ "$has_counter" = 1 ]; then
        if [ "$unpushed" = 1 ] || [ "$count" -gt 0 ]; then
            severity=warning
        else
            severity=muted
        fi
        text=''
        [ "$unpushed" = 1 ] && text='!'
        text+=$count
        role "$severity" 0 "$text"
        out+="$R "
    fi

    if [ -n "$branch" ]; then
        role branch 0 "$branch"
        out+="$R "
    fi

    role punctuation 0 '~'
    out+="$R"
    role owner 0 "$owner"
    out+="$R"
    role divider 0 '/'
    out+="$R"
    role repo 0 "$repo"
    out+="$R"
    role punctuation 0 '.git'
    out+="$R"

    local at_root=0
    [ -z "$rel" ] && at_root=1
    role path_marker "$at_root" ':/'
    out+="$R"

    if [ "$at_root" = 0 ]; then
        local -a segments=()
        IFS='/' read -ra segments <<<"$rel"
        local i last=$((${#segments[@]} - 1))
        for ((i = 0; i <= last; i++)); do
            if [ "$i" -lt "$last" ]; then
                role directory 0 "${segments[i]}"
                out+="$R"
                role punctuation 0 '/'
                out+="$R"
            else
                role path 0 "${segments[i]}"
                out+="$R"
            fi
        done
    fi

    R=$out
}


# ---------------------------------------------------------------------------
# main: port of `src/lib.rs` and `src/main.rs`
# ---------------------------------------------------------------------------

# Rate-limit reset strings, shared with `row_limits`.
FIVE_RESET=''
SEVEN_RESET=''

# Echoes `$1`, or `$2` when `$1` is empty.
#
# The fallback chains in `src/lib.rs` route through its `non_empty` so that an
# explicit `""` falls through just as a missing key does, which is what the
# original Python script's `or` chains did. Same idea, and in bash it is simply
# what `[ -z ]` already means.
first_non_empty() {
    if [ -n "$1" ]; then R=$1; else R=$2; fi
}

# Renders both lines for the already-parsed payload in `P`.
render_payload() {
    local cwd model_name effort now

    first_non_empty "${P[cwd]}" "${P[cwd_fallback]}"
    cwd=$R
    if [ -z "$cwd" ]; then
        process_cwd
        cwd=$R
    fi

    first_non_empty "${P[model_name]}" "${P[model_id]}"
    model_name=$R
    [ -z "$model_name" ] && model_name='?'

    # The payload's own `effort.level` is Claude Code's fully resolved live
    # value, so it wins outright; the settings cascade only covers older
    # versions that do not send it.
    effort=${P[effort]}
    if [ -z "$effort" ] && [ -n "${P[model_id]}" ]; then
        settings_effort_level "$cwd" "${P[model_id]}"
        effort=$R
    fi
    [ -z "$effort" ] && effort='?'
    # DIVERGENCE: `${var^^}` does handle single-character mappings in the
    # current locale (`ü` uppercases), but not the one-to-many mappings Rust's
    # `to_uppercase` performs: `straße` becomes `STRAßE` here and `STRASSE`
    # under the binary. Effort levels are ASCII keywords, so this only shows on
    # a payload that invents a non-ASCII one.
    effort=${effort^^}

    now_seconds
    now=$R
    fmt_reset "${P[five_reset]}" "$now"
    FIVE_RESET=$R
    fmt_reset "${P[seven_reset]}" "$now"
    SEVEN_RESET=$R

    local where owner repo has_counter=0
    if git_locate "$cwd"; then
        owner=$GIT_OWNER
        [ -z "$owner" ] && owner='chewygumxx'
        repo=$GIT_REPO
        if [ -z "$repo" ]; then
            path_split "$GIT_ROOT"
            repo=''
            [ ${#PATH_PARTS[@]} -gt 0 ] && repo=${PATH_PARTS[-1]}
        fi
        repo_status_query "$GIT_ROOT" "$GIT_BRANCH" "${P[session_id]}"
        if [ "$STATUS_AVAILABLE" = 1 ] &&
            { [ "$STATUS_DIRTY" -gt 0 ] || [ "$STATUS_UNPUSHED" = 1 ]; }; then
            has_counter=1
        fi
        row_where_repo "$GIT_BRANCH" "$owner" "$repo" "$GIT_REL_PATH" \
            "$has_counter" "$STATUS_DIRTY" "$STATUS_UNPUSHED"
    else
        row_where_pwd "$cwd"
    fi
    where=$R

    local config tokens limits sep
    row_config "$model_name" "$effort"
    config=$R
    row_tokens
    tokens=$R
    row_limits
    limits=$R
    separator
    sep=$R

    printf '%s\n%s%s%s %s\n' "$where" "$config" "$sep" "$tokens" "$limits"
}

# Reads the payload from `--sample <file>` when given and stdin otherwise, then
# renders. `--no-color` forces plain output; unrecognized arguments are ignored,
# as they are by the Rust `parse_args`.
main() {
    local sample='' no_color=0 raw

    while [ $# -gt 0 ]; do
        case $1 in
            --sample)
                shift
                sample=${1-}
                ;;
            --no-color) no_color=1 ;;
        esac
        shift
    done

    if [ -n "$sample" ]; then
        # DIVERGENCE: the wording after the path is bash's business rather than
        # Rust's `std::io::Error`; the stream and the exit status match.
        if [ -d "$sample" ] || [ ! -r "$sample" ]; then
            printf "claude-status-line: couldn't read %s\n" "$sample" >&2
            return 1
        fi
        raw=$(<"$sample")
    else
        # An unreadable or empty stdin still leaves a valid (empty) payload,
        # which renders as the all-defaults status line rather than an error.
        IFS= read -r -d '' raw <&0
    fi

    if [ "$no_color" = 1 ]; then
        TIER='plain'
    else
        detect_tier
    fi

    payload_parse "$raw"
    render_payload
}

# Only run when executed, so that `tests/compare-with-rust.sh` (and any other
# caller) can source this file to exercise individual functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
