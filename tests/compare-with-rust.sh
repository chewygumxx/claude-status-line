#!/usr/bin/env bash
# vim:set expandtab shiftwidth=4 filetype=bash:
# SPDX-License-Identifier: GPL-3.0-only
#
#
# ~chewygumxx/claude-status-line.git
# ::: :/tests/compare-with-rust.sh
#
#

# Differential check: renders the same payloads through the compiled Rust
# binary and through `claude-status-line.sh` and compares the raw bytes,
# escape sequences included.
#
# The bash script exists to stand in for the binary, so "looks about right" is
# not a useful standard for it: every case below asserts the two implementations
# produce identical output. Cases are drawn from `tests/fixtures/`, from the
# colour-detection rules in `src/theme.rs`, from the edge cases in
# `.claude/reference/initial_errors.md`, and from the payload type-strictness of
# `src/payload.rs`.
#
# Usage:
#   cargo build --release && tests/compare-with-rust.sh [-v]
#
# `-v` prints every case rather than only the failures. Set
# `CLAUDE_STATUS_LINE_BIN` to compare against a binary elsewhere.

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASH_IMPL="$REPO_ROOT/claude-status-line.sh"
VERBOSE=0
[ "${1-}" = '-v' ] && VERBOSE=1

BIN=${CLAUDE_STATUS_LINE_BIN-}
if [ -z "$BIN" ]; then
    for candidate in "$REPO_ROOT/target/release/claude-status-line" \
        "$REPO_ROOT/target/debug/claude-status-line"; do
        if [ -x "$candidate" ]; then
            BIN=$candidate
            break
        fi
    done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    printf 'no binary to compare against: build one with cargo build --release first\n' >&2
    exit 2
fi
if [ ! -x "$BASH_IMPL" ]; then
    printf 'missing or non-executable %s\n' "$BASH_IMPL" >&2
    exit 2
fi

PASS=0
FAIL=0

# A scratch area for the synthetic repositories and settings trees below, so no
# case has to touch this checkout.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-status-line-compare-XXXXXX") || exit 2
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

# Renders `$2` through both implementations under the environment given in the
# `CASE_ENV` array, and compares the bytes.
CASE_ENV=()
compare() {
    local label=$1 payload=$2
    local rust_out bash_out rust_hex bash_hex

    rust_out=$(printf '%s' "$payload" | env "${CASE_ENV[@]}" "$BIN" 2>/dev/null)
    bash_out=$(printf '%s' "$payload" | env "${CASE_ENV[@]}" "$BASH_IMPL" 2>/dev/null)
    rust_hex=$(printf '%s' "$rust_out" | od -An -tx1 | tr -d ' \n')
    bash_hex=$(printf '%s' "$bash_out" | od -An -tx1 | tr -d ' \n')

    if [ "$rust_hex" = "$bash_hex" ]; then
        PASS=$((PASS + 1))
        [ "$VERBOSE" = 1 ] && printf 'ok    %s\n' "$label"
        return 0
    fi
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$label"
    printf '%s' "$rust_out" | cat -v | sed 's/^/        rust: /'
    printf '%s' "$bash_out" | cat -v | sed 's/^/        bash: /'
    return 1
}

# A payload with every field populated, so a case only has to vary what it is
# actually testing. The reset epochs are fixed rather than relative to now, so
# the weekday-prefixed form is exercised deterministically (both
# implementations read the same clock, but a fixed epoch also keeps the failure
# output readable).
full_payload() {
    local cwd=$1
    printf '{"workspace":{"current_dir":"%s"},' "$cwd"
    printf '"model":{"display_name":"Claude Opus 5","id":"claude-opus-5"},'
    printf '"effort":{"level":"high"},'
    printf '"context_window":{"used_percentage":42,"total_input_tokens":949,'
    printf '"total_output_tokens":13133,"current_usage":{"input_tokens":1,'
    printf '"output_tokens":36,"cache_creation_input_tokens":277,'
    printf '"cache_read_input_tokens":64600}},'
    printf '"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1790500000},'
    printf '"seven_day":{"used_percentage":88,"resets_at":1790600000}},'
    printf '"cost":{"total_duration_ms":754000}}'
}

# A payload carrying only `context_window.used_percentage`, for rounding cases.
pct_payload() {
    printf '{"model":{"display_name":"M"},"context_window":{"used_percentage":%s}}' "$1"
}

# A payload carrying only token counts, for compaction cases.
tokens_payload() {
    printf '{"model":{"display_name":"M"},"context_window":{"total_input_tokens":%s,' "$1"
    printf '"total_output_tokens":%s,"current_usage":{"input_tokens":%s,' "$1" "$1"
    printf '"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}' "$1" "$1"
}

HERMETIC_HOME="$WORK/home"
mkdir -p "$HERMETIC_HOME"


# ---------------------------------------------------------------------------
# 1. Fixtures, at each forced colour tier
# ---------------------------------------------------------------------------

for fixture in "$REPO_ROOT"/tests/fixtures/*.json; do
    name=$(basename -- "$fixture" .json)
    raw=$(<"$fixture")
    for forced in FORCE_COLOR=3 FORCE_COLOR=2 FORCE_COLOR=1 NO_COLOR=1; do
        CASE_ENV=("HOME=$HERMETIC_HOME" "$forced")
        compare "fixture $name ($forced)" "$raw"
    done
done


# ---------------------------------------------------------------------------
# 2. Colour tier detection
#
# Every rule `src/theme.rs` relies on `supports-color` for, including the
# suffix-matching `TERM` cases and the `FORCE_COLOR` parsing quirks. The bash
# script reads the real environment out of `/proc/self/environ` precisely so
# these agree: bash injects a `TERM=dumb` shell variable of its own whenever
# `TERM` is absent, which would otherwise suppress colour the binary emits.
# ---------------------------------------------------------------------------

tier_cases=(
    '' 'TERM=' 'TERM=dumb' 'TERM=dumb-foo' 'TERM=xterm' 'TERM=alacritty'
    'TERM=foot-extra' 'TERM=xterm-88color' 'TERM=xterm-256color' 'TERM=256color'
    'TERM=xterm-256color-foo' 'TERM=foo256colorbar' 'TERM=rxvt-unicode-256color'
    'TERM=kitty-direct' 'TERM=xterm-truecolor'
    'COLORTERM=truecolor' 'COLORTERM=24bit' 'COLORTERM=' 'COLORTERM=1'
    'TERM=xterm-256color COLORTERM=truecolor' 'TERM=dumb COLORTERM=truecolor'
    'TERM=xterm NO_COLOR=1' 'TERM=xterm NO_COLOR=0' 'TERM=xterm NO_COLOR='
    'NO_COLOR=1 FORCE_COLOR=1' 'FORCE_COLOR=' 'FORCE_COLOR=true'
    'FORCE_COLOR=false TERM=xterm-256color' 'FORCE_COLOR=0 CLICOLOR_FORCE=1'
    'FORCE_COLOR=-1' 'FORCE_COLOR=abc' 'FORCE_COLOR=9' 'FORCE_COLOR=2'
    'TERM=dumb FORCE_COLOR=3'
    'CLICOLOR_FORCE=1' 'CLICOLOR_FORCE=2' 'CLICOLOR_FORCE=0 TERM=xterm-256color'
    'TERM_PROGRAM=iTerm.app' 'TERM_PROGRAM=Apple_Terminal' 'TERM_PROGRAM=mintty'
    'TERM=xterm TERM_PROGRAM=Apple_Terminal'
    'CI=1' 'CI=' 'CI=true GITHUB_ACTIONS=true' 'TERM=screen-256color CI=1'
)
tier_payload=$(full_payload "$WORK/not-a-repo")
mkdir -p "$WORK/not-a-repo"
for spec in "${tier_cases[@]}"; do
    # shellcheck disable=SC2206 # deliberate word splitting of the case spec
    CASE_ENV=("HOME=$HERMETIC_HOME" ${spec})
    compare "tier [${spec:-unset}]" "$tier_payload"
done


# ---------------------------------------------------------------------------
# 3. Repository shapes
# ---------------------------------------------------------------------------

# Synthetic `.git` layouts, the same shapes `src/git.rs`'s unit tests build.
mkdir -p "$WORK/plain/.git" "$WORK/plain/a/b/c"
printf 'ref: refs/heads/main\n' >"$WORK/plain/.git/HEAD"
printf '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = git@github.com:owner/name.git\n' \
    >"$WORK/plain/.git/config"

mkdir -p "$WORK/wt/real-gitdir" "$WORK/wt/tree/sub"
printf 'ref: refs/heads/feature\n' >"$WORK/wt/real-gitdir/HEAD"
printf 'gitdir: %s\n' "$WORK/wt/real-gitdir" >"$WORK/wt/tree/.git"

mkdir -p "$WORK/detached/.git"
printf 'abcdef0123456789\n' >"$WORK/detached/.git/HEAD"

mkdir -p "$WORK/blank-head/.git"
printf '   \n' >"$WORK/blank-head/.git/HEAD"

mkdir -p "$WORK/https-origin/.git"
printf 'ref: refs/heads/main\n' >"$WORK/https-origin/.git/HEAD"
printf '[remote "origin"]\n\turl = https://github.com/someone/thing\n' \
    >"$WORK/https-origin/.git/config"

mkdir -p "$WORK/no-origin/.git/x"
printf 'ref: refs/heads/topic\n' >"$WORK/no-origin/.git/HEAD"

mkdir -p "$HERMETIC_HOME/under-home/deep"

repo_cases=(
    "$WORK/plain"
    "$WORK/plain/a/b/c"
    "$WORK/plain//a//b"
    "$WORK/plain/./a"
    "$WORK/plain/a/"
    "$WORK/wt/tree"
    "$WORK/wt/tree/sub"
    "$WORK/detached"
    "$WORK/blank-head"
    "$WORK/https-origin"
    "$WORK/no-origin"
    "$WORK/not-a-repo"
    "$HERMETIC_HOME"
    "$HERMETIC_HOME/under-home/deep"
    "$REPO_ROOT"
    "$REPO_ROOT/src/format"
)
for cwd in "${repo_cases[@]}"; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
    compare "where [$cwd]" "$(full_payload "$cwd")"
done

# A real repository, so the dirty/unpushed counter is exercised rather than
# skipped: `git status` fails outright in the synthetic layouts above, which is
# the "counter omitted" path, not the "counter shown" one.
if command -v git >/dev/null 2>&1; then
    real="$WORK/real"
    mkdir -p "$real"
    git -C "$real" init --initial-branch=main --quiet
    git -C "$real" config user.email test@example.com
    git -C "$real" config user.name Test
    printf 'hello\n' >"$real/a.txt"
    git -C "$real" add a.txt
    git -C "$real" commit --quiet -m initial
    git -C "$real" update-ref refs/remotes/origin/main refs/heads/main

    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
    compare 'counter: clean and pushed' "$(full_payload "$real")"

    printf 'changed\n' >"$real/a.txt"
    compare 'counter: one dirty file' "$(full_payload "$real")"

    printf 'more\n' >"$real/b.txt"
    git -C "$real" add b.txt
    git -C "$real" commit --quiet -m second
    compare 'counter: unpushed commit' "$(full_payload "$real")"

    git -C "$real" checkout --quiet --detach HEAD
    compare 'counter: detached in real repo' "$(full_payload "$real")"

    # With a session id both implementations cache, each in its own file. The
    # first pair of renders populates those caches and the second pair reads
    # them back, so agreement is checked on both paths.
    session="compare-$$"
    cached_payload=$(printf '%s' "$(full_payload "$real")" |
        sed "s/^{/{\"session_id\":\"$session\",/")
    compare 'counter: cached, first render' "$cached_payload"
    compare 'counter: cached, second render' "$cached_payload"
fi


# ---------------------------------------------------------------------------
# 4. Payload type strictness
#
# `serde` abandons the whole document over one ill-typed field, so each of these
# must lose the model name too, not just the offending value.
# ---------------------------------------------------------------------------

strict_cases=(
    '{"model":{"display_name":"M"},"context_window":{"total_input_tokens":"949"}}'
    '{"model":{"display_name":"M"},"context_window":{"total_input_tokens":949.0}}'
    '{"model":{"display_name":"M"},"context_window":{"total_input_tokens":-5}}'
    '{"model":{"display_name":"M"},"context_window":{"total_input_tokens":99999999999999999999}}'
    '{"model":{"display_name":"M"},"context_window":{"total_input_tokens":18446744073709551615}}'
    '{"model":{"display_name":"M"},"context_window":{"used_percentage":true}}'
    '{"model":{"display_name":"M"},"context_window":{"used_percentage":null}}'
    '{"model":{"display_name":"M"},"context_window":{"used_percentage":1e2}}'
    '{"model":{"display_name":"M"},"context_window":null}'
    '{"model":{"display_name":"M"},"effort":{"level":5}}'
    '{"model":{"display_name":"M"},"session_id":5}'
    '{"model":{"display_name":"M"},"cost":{"total_duration_ms":"x"}}'
    '{"model":{"display_name":"M"},"cost":{"total_duration_ms":754000}}'
    '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"resets_at":1.5}}}'
    '{"model":{"display_name":"M"},"rate_limits":{"five_hour":null}}'
    '{"model":{"display_name":"M"},"workspace":{"current_dir":123}}'
    '{"model":"M"}'
    '{"model":{"display_name":"M"},"unknown_key":1}'
    '{"model":{"display_name":""},"model_id":""}'
    '{"model":{"display_name":"","id":"claude-sonnet-5"}}'
    '{"effort":{"level":""}}'
    '{}'
    'null'
    '[]'
    '42'
    '"oops"'
    ''
    'not json at all'
    '{"unclosed":'
)
for payload in "${strict_cases[@]}"; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
    compare "strict [${payload:0:60}]" "$payload"
done


# ---------------------------------------------------------------------------
# 5. Rounding, compaction, and reset-time boundaries
# ---------------------------------------------------------------------------

for pct in 0 -0.4 -0.6 0.5 49 49.5 49.6 50 78.5 79.5 79.6 80 99.5 100 255 255.4 255.5 300 1e2; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
    compare "pct [$pct]" "$(pct_payload "$pct")"
done

for n in 0 1 999 1000 9999 10000 10001 10450 10500 10550 99999 999999 1000000 \
    1000001 12345678 18446744073709551615; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
    compare "tokens [$n]" "$(tokens_payload "$n")"
done

reset_payload() {
    printf '{"model":{"display_name":"M"},"rate_limits":{"five_hour":'
    printf '{"used_percentage":10,"resets_at":%s},"seven_day":' "$1"
    printf '{"used_percentage":20,"resets_at":%s}}}' "$2"
}
now=$(date +%s)
reset_cases=(
    "0 0"
    "$((now + 60)) $((now + 60))"
    "$((now + 3600)) $((now + 86400))"
    "$((now + 43199)) $((now + 43201))"
    "$((now - 60)) $((now - 86400))"
    "1 2"
    "-1 -86400"
    "999999999999999 -999999999999999"
)
for spec in "${reset_cases[@]}"; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
    compare "reset [$spec]" "$(reset_payload "${spec% *}" "${spec#* }")"
done

# The representable-range bounds are checked in UTC specifically. Anywhere east
# of UTC the binary panics within one offset's distance of the upper bound, not
# merely at it, so a zone with a positive offset cannot test the bound itself.
# Section 8 pins that panic down separately.
for spec in "253402300799 253402300800" "-377705116800 -377705116801"; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3' 'TZ=UTC')
    compare "reset bound in UTC [$spec]" "$(reset_payload "${spec% *}" "${spec#* }")"
done

# The reset row renders in local time, so a couple of zones are worth checking
# rather than only whichever one this machine happens to use. Asia/Kolkata is
# there for its half-hour offset.
for tz in UTC Australia/Sydney America/Los_Angeles Asia/Kolkata; do
    CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3' "TZ=$tz")
    compare "reset in $tz" "$(reset_payload "$((now + 3600))" "$((now + 86400))")"

    # Resets far enough out to sit on the other side of a daylight-saving
    # transition. Rust applies *today's* offset to every timestamp rather than
    # the offset in force at the reset, so these differ by an hour from what
    # `date -d @<epoch>` alone would report in a DST-observing zone.
    compare "reset across DST in $tz" \
        "$(reset_payload "$((now + 86400 * 120))" "$((now - 86400 * 240))")"
done


# ---------------------------------------------------------------------------
# 6. Effort resolution through the settings cascade
# ---------------------------------------------------------------------------

cascade_case() {
    local name=$1 local_json=$2 project_json=$3 home_json=$4 model=$5
    local dir="$WORK/cascade-$name" home="$WORK/cascade-home-$name"
    mkdir -p "$dir/.claude" "$home/.claude"
    [ -n "$local_json" ] && printf '%s' "$local_json" >"$dir/.claude/settings.local.json"
    [ -n "$project_json" ] && printf '%s' "$project_json" >"$dir/.claude/settings.json"
    [ -n "$home_json" ] && printf '%s' "$home_json" >"$home/.claude/settings.json"

    CASE_ENV=("HOME=$home" 'FORCE_COLOR=3')
    compare "cascade $name" \
        "$(printf '{"workspace":{"current_dir":"%s"},"model":{"id":"%s","display_name":"M"}}' "$dir" "$model")"
}

cascade_case local-wins '{"effortLevel":"MAX"}' '{"effortLevel":"LOW"}' '' claude-sonnet-5
cascade_case empty-falls-through '{"effortLevel":""}' '{"effortLevel":"HIGH"}' '' claude-sonnet-5
cascade_case null-falls-through '{"effortLevel":null}' '{"effortLevel":"MAX"}' '' claude-sonnet-5
cascade_case per-model '' '{"effortLevel":"low","modelSettings":{"claude-sonnet-5":{"effortLevel":"high"}}}' '' claude-sonnet-5
cascade_case per-model-other '' '{"effortLevel":"low","modelSettings":{"claude-opus-5":{"effortLevel":"xhigh"}}}' '' claude-sonnet-5
cascade_case nested-merge '{"modelSettings":{"claude-sonnet-5":{"effortLevel":""}}}' '{"modelSettings":{"claude-sonnet-5":{"effortLevel":"medium"}}}' '' claude-sonnet-5
cascade_case malformed '{not valid json' '{"effortLevel":"HIGH"}' '' claude-sonnet-5
cascade_case home-fallback '' '' '{"effortLevel":"xhigh"}' claude-sonnet-5
cascade_case home-per-model '' '' '{"modelSettings":{"claude-opus-5":{"effortLevel":"max"}}}' claude-opus-5
cascade_case not-an-object '' '{"modelSettings":"a string"}' '' claude-sonnet-5
cascade_case payload-wins '{"effortLevel":"LOW"}' '' '' claude-sonnet-5

# The payload's own `effort.level` must win over anything in the cascade.
CASE_ENV=("HOME=$WORK/cascade-home-payload-wins" 'FORCE_COLOR=3')
mkdir -p "$WORK/cascade-payload-wins/.claude" "$WORK/cascade-home-payload-wins"
printf '{"effortLevel":"LOW"}' >"$WORK/cascade-payload-wins/.claude/settings.json"
compare 'cascade overridden by payload effort' \
    "$(printf '{"workspace":{"current_dir":"%s"},"model":{"id":"claude-sonnet-5","display_name":"M"},"effort":{"level":"xhigh"}}' \
        "$WORK/cascade-payload-wins")"


# ---------------------------------------------------------------------------
# 7. Working-directory fallbacks and the command line
# ---------------------------------------------------------------------------

CASE_ENV=("HOME=$HERMETIC_HOME" 'FORCE_COLOR=3')
compare 'cwd falls back to top-level key' \
    "$(printf '{"cwd":"%s","model":{"display_name":"M"}}' "$WORK/plain/a")"
compare 'empty current_dir falls through to cwd' \
    "$(printf '{"workspace":{"current_dir":""},"cwd":"%s","model":{"display_name":"M"}}' "$WORK/plain")"
compare 'both cwd keys empty' '{"workspace":{"current_dir":""},"cwd":"","model":{"display_name":"M"}}'
compare 'relative current_dir' '{"workspace":{"current_dir":"src"},"model":{"display_name":"M"}}'

# `--sample`, `--no-color`, and unknown-argument handling, which live in
# `src/main.rs` rather than in the render path.
cli_compare() {
    local label=$1
    shift
    local rust_out bash_out rust_code bash_code
    rust_out=$(env "HOME=$HERMETIC_HOME" FORCE_COLOR=3 "$BIN" "$@" </dev/null 2>/dev/null)
    rust_code=$?
    bash_out=$(env "HOME=$HERMETIC_HOME" FORCE_COLOR=3 "$BASH_IMPL" "$@" </dev/null 2>/dev/null)
    bash_code=$?
    if [ "$rust_out" = "$bash_out" ] && [ "$rust_code" = "$bash_code" ]; then
        PASS=$((PASS + 1))
        [ "$VERBOSE" = 1 ] && printf 'ok    cli %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  cli %s\n' "$label"
        printf '        rust (exit %s): %s\n' "$rust_code" "$(printf '%s' "$rust_out" | cat -v)"
        printf '        bash (exit %s): %s\n' "$bash_code" "$(printf '%s' "$bash_out" | cat -v)"
    fi
}

cli_compare '--sample fixture' --sample "$REPO_ROOT/tests/fixtures/normal.json"
cli_compare '--sample fixture --no-color' --sample "$REPO_ROOT/tests/fixtures/normal.json" --no-color
cli_compare '--no-color with empty stdin' --no-color
cli_compare '--sample missing file' --sample "$WORK/definitely-not-here.json"
cli_compare '--sample a directory' --sample "$WORK"
cli_compare '--sample with no value' --sample
cli_compare 'unknown argument' --frobnicate
cli_compare 'no arguments'



# ---------------------------------------------------------------------------
# 8. Known divergence: the Rust binary panics at the upper epoch bound
#
# `src/format/time.rs:33` applies the local offset with `to_offset`, which panics
# when the shifted value leaves `OffsetDateTime`'s valid range. So a payload with
# `resets_at` at the maximum valid timestamp aborts the whole render in any zone
# east of UTC, printing nothing, while the bash port renders the row.
#
# This is asserted rather than skipped so that the suite speaks up if either
# side changes: if the binary stops panicking here, this case fails and the
# corresponding DIVERGENCE note in `claude-status-line.sh` should come out.
# ---------------------------------------------------------------------------

divergence_payload=$(printf '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":253402300799}}}')
rust_out=$(printf '%s' "$divergence_payload" |
    env "HOME=$HERMETIC_HOME" TZ=Australia/Sydney FORCE_COLOR=3 "$BIN" 2>/dev/null)
rust_code=$?
bash_out=$(printf '%s' "$divergence_payload" |
    env "HOME=$HERMETIC_HOME" TZ=Australia/Sydney FORCE_COLOR=3 "$BASH_IMPL" 2>/dev/null)
if [ "$rust_code" != 0 ] && [ -z "$rust_out" ] && [ -n "$bash_out" ]; then
    PASS=$((PASS + 1))
    [ "$VERBOSE" = 1 ] && printf 'ok    known divergence: binary panics at max epoch\n'
else
    FAIL=$((FAIL + 1))
    printf 'FAIL  known divergence at max epoch changed shape (binary exit %s)\n' "$rust_code"
    printf '        rust: %s\n' "$(printf '%s' "$rust_out" | cat -v)"
    printf '        bash: %s\n' "$(printf '%s' "$bash_out" | cat -v)"
fi


# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
