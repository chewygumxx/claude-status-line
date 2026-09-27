#!/usr/bin/env bash
# vim:set expandtab shiftwidth=4 filetype=bash:
# SPDX-License-Identifier: GPL-3.0-only
#
#
# ~chewygumxx/claude-status-line.git
# ::: :/tests/check.sh
#
#

# Every check this repository has, in one place, so that what runs locally and
# what runs in CI cannot drift apart: `.github/workflows/ci.yaml` invokes this
# file rather than listing the commands again.
#
# Usage:
#   tests/check.sh [-v] [step ...]
#
# With no step names, everything runs. Named steps run only those, which is
# what makes this usable as an inner loop: `tests/check.sh differential` after
# touching the bash port. `-v` is passed through to the differential suite.
#
# Every step runs even after an earlier one fails, because a formatting
# complaint should not hide a test failure underneath it. The exit status is
# non-zero if any step failed. A step whose tool is missing is skipped and
# reported as such rather than quietly passing.
#
# Steps: format clippy test shellcheck differential

set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT" || exit 2

VERBOSE=''
WANTED=()
for arg in "$@"; do
    case $arg in
        -v) VERBOSE='-v' ;;
        -h | --help)
            sed -n '11,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -*)
            printf 'check: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
        *) WANTED+=("$arg") ;;
    esac
done

PASSED=0
FAILED=0
SKIPPED=0
FAILED_STEPS=()

# GitHub renders `::group::` as a collapsible section and `::error::` as an
# annotation against the run. Neither is worth reading in a terminal, so they
# only appear when there is a GitHub to read them.
in_actions() { [ -n "${GITHUB_ACTIONS-}" ]; }

wanted() {
    [ ${#WANTED[@]} -eq 0 ] && return 0
    local step
    for step in "${WANTED[@]}"; do
        [ "$step" = "$1" ] && return 0
    done
    return 1
}

# Runs `$3...` as step `$1`, unless the tool named in `$2` is absent.
step() {
    local name=$1 tool=$2
    shift 2
    wanted "$name" || return 0

    if ! command -v "$tool" > /dev/null 2>&1; then
        SKIPPED=$((SKIPPED + 1))
        printf '\nSKIP  %s (no %s on PATH)\n' "$name" "$tool"
        return 0
    fi

    in_actions && printf '::group::%s\n' "$name"
    printf '\n===== %s =====\n' "$name"
    if "$@"; then
        PASSED=$((PASSED + 1))
        in_actions && printf '::endgroup::\n'
        printf 'ok    %s\n' "$name"
    else
        local code=$?
        FAILED=$((FAILED + 1))
        FAILED_STEPS+=("$name")
        in_actions && printf '::endgroup::\n'
        in_actions && printf '::error title=%s::%s failed with exit status %s\n' \
            "$name" "$name" "$code"
        printf 'FAIL  %s (exit %s)\n' "$name" "$code"
    fi
}

step format cargo cargo fmt --all --check
step clippy cargo cargo clippy --locked --all-targets -- -D warnings
step test cargo cargo test --locked
step shellcheck shellcheck shellcheck claude-status-line.sh tests/*.sh

# The differential suite compares against a built binary, so it needs one. The
# build is folded into the step rather than being a step of its own: on its
# own it would duplicate what `test` and `clippy` already prove compiles.
differential() {
    cargo build --locked --release || return $?
    tests/compare-with-rust.sh ${VERBOSE:+"$VERBOSE"}
}
step differential cargo differential

printf '\n===== summary =====\n'
if [ "$SKIPPED" != 0 ]; then
    printf '%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
else
    printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
fi
if [ "$FAILED" != 0 ]; then
    printf 'failed: %s\n' "${FAILED_STEPS[*]}"
    exit 1
fi
