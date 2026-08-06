#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted $names are jq variables, not shell ones
# Shows what updating flakeDirectory's (arg 1) inputs and rebuilding would change, compared
# with what is running now.
#
# Re-resolves the inputs into a scratch lock file (same step as check-flake-updates.sh, the
# real flake.lock is never touched) and evaluates the flake output attribute (arg 2, defaulting
# to this host's NixOS toplevel) against it - working tree as on disk, uncommitted edits
# included, i.e. what `nix flake update && nixos-rebuild switch` would build. That .drv is
# diffed with `dix` against the *running* system's .drv (arg 3, default /run/current-system
# for nixosConfigurations outputs). So the diff covers both pending input updates and anything
# not yet rebuilt, and is meaningful even when flake.lock is already up to date.
#
# If the running system's .drv has been garbage-collected (or there is no running system for
# this output, e.g. homeConfigurations), the baseline falls back to evaluating the flake with
# its current flake.lock - "baseline" in the output says which one was used. Nothing is built.
#
# A .drv closure also contains build-time inputs (source tarballs, patches, vendored deps,
# completions...), so dix's raw output is filtered down to real package version changes.
#
# `dix` and `jq` are used from PATH if present, otherwise fetched via `nix run nixpkgs#...`.
#
# Prints a single JSON object and always exits 0:
#   {"status": "error", "message": "..."}
#   {"status": "same", ...baseline fields}    - nothing would change
#   {"status": "ok", ...baseline fields,
#    "packages": [{"name", "status": "upgraded|downgraded|added|removed",
#                  "changes": [{"old": "<ver>|null", "new": "<ver>|null"}]}],
#    "counts": {"upgraded", "downgraded", "added", "removed"},
#    "paths": {"old", "new"}, "sizeOld", "sizeNew"}   - sizes in bytes, of the .drv closure
# baseline fields: "baseline": "running" | "lock", "running": <running system out path> | null
set -euo pipefail

NIX=(nix --extra-experimental-features "nix-command flakes")
if command -v dix >/dev/null 2>&1; then
    DIX=(dix)
else
    DIX=("${NIX[@]}" run nixpkgs#dix --)
fi
if command -v jq >/dev/null 2>&1; then
    JQ=(jq)
else
    JQ=("${NIX[@]}" run nixpkgs#jq --)
fi

FLAKE_DIR="${1:-}"
ATTR="${2:-}"
[ -n "$ATTR" ] || ATTR="nixosConfigurations.$(hostname).config.system.build.toplevel"
CURRENT="${3:-}"
if [ -z "$CURRENT" ] && [[ "$ATTR" == nixosConfigurations.* ]]; then
    CURRENT=/run/current-system
fi

TMPDIR_="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_"' EXIT

fail() {
    local msg="$1"
    if [ -s "$TMPDIR_/err" ]; then
        # Last nix "error:" line is usually the most useful one.
        local detail
        detail="$(grep -E '^error:' "$TMPDIR_/err" | tail -n 1 | sed 's/^error: *//' || true)"
        [ -n "$detail" ] && msg="$msg: $detail"
    fi
    "${JQ[@]}" -cn --arg m "$msg" '{status: "error", message: $m}' 2>/dev/null \
        || printf '{"status":"error","message":"%s"}\n' "$(printf '%s' "$msg" | tr -d '"\\\n')"
    exit 0
}

[ -n "$FLAKE_DIR" ] || fail "no flake directory given"
[ -f "$FLAKE_DIR/flake.nix" ] || fail "$FLAKE_DIR/flake.nix not found"
[ -f "$FLAKE_DIR/flake.lock" ] || fail "$FLAKE_DIR/flake.lock not found"

"${NIX[@]}" flake update --flake "$FLAKE_DIR" --output-lock-file "$TMPDIR_/new.lock" \
    --quiet 2>"$TMPDIR_/err" || fail "could not update flake inputs"

NEW="$("${NIX[@]}" eval --raw "$FLAKE_DIR#$ATTR.drvPath" \
    --reference-lock-file "$TMPDIR_/new.lock" 2>"$TMPDIR_/err")" \
    || fail "could not evaluate $ATTR with updated inputs"

# Baseline: the running system's .drv if it's still in the store, else the current flake.lock.
BASELINE=lock
RUNNING=""
OLD=""
if [ -n "$CURRENT" ] && [ -e "$CURRENT" ]; then
    RUNNING="$(readlink -f "$CURRENT")"
    DRV="$(nix-store -qd "$RUNNING" 2>/dev/null || true)"
    if [ -n "$DRV" ] && [ "$DRV" != "unknown-deriver" ] && [ -e "$DRV" ]; then
        OLD="$DRV"
        BASELINE=running
    fi
fi
if [ -z "$OLD" ]; then
    OLD="$("${NIX[@]}" eval --raw "$FLAKE_DIR#$ATTR.drvPath" 2>"$TMPDIR_/err")" \
        || fail "could not evaluate $ATTR"
fi

with_baseline() {
    "${JQ[@]}" -c --arg baseline "$BASELINE" --arg running "$RUNNING" \
        '. + {baseline: $baseline, running: (if $running == "" then null else $running end)}'
}

if [ "$OLD" = "$NEW" ]; then
    echo '{"status":"same"}' | with_baseline
    exit 0
fi

"${DIX[@]}" --color=never diff --output=json "$OLD" "$NEW" >"$TMPDIR_/diff.json" \
    2>"$TMPDIR_/err" || fail "dix failed"

"${JQ[@]}" -c -f "$(dirname "$0")/dix-filter.jq" "$TMPDIR_/diff.json" \
    | with_baseline || fail "could not parse dix output"
