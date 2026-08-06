#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted $names are jq variables, not shell ones
# Checks whether the running system (/run/current-system) is what flakeDirectory (arg 1)
# currently evaluates to - i.e. whether a rebuild is pending. This is independent of whether
# flake.lock is behind upstream (check-flake-updates.sh): bumping the lock or editing the
# config without switching leaves the inputs "up to date" but the system stale.
#
# The flake output attribute (arg 2) defaults to this host's NixOS toplevel. The flake is
# evaluated as it is on disk (working tree, uncommitted edits included) - the same thing
# `nixos-rebuild switch --flake .` / `nh os switch .` would build. Nothing is built.
#
# Package-level differences are not computed here: diff-flake-update.sh diffs the running
# system against the flake with updated inputs, which covers a pending rebuild too.
#
# Prints a single JSON object and always exits 0:
#   {"status": "error", "message": "..."}
#   {"status": "synced", "generation", "switchedAt"}
#   {"status": "behind", "generation", "switchedAt", "running", "flake"}
# generation/switchedAt (unix seconds) describe the current system profile link, or null.
set -euo pipefail

NIX=(nix --extra-experimental-features "nix-command flakes")
if command -v jq >/dev/null 2>&1; then
    JQ=(jq)
else
    JQ=("${NIX[@]}" run nixpkgs#jq --)
fi

FLAKE_DIR="${1:-}"
ATTR="${2:-}"
[ -n "$ATTR" ] || ATTR="nixosConfigurations.$(hostname).config.system.build.toplevel"

TMPDIR_="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_"' EXIT

fail() {
    local msg="$1"
    if [ -s "$TMPDIR_/err" ]; then
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
[ -e /run/current-system ] || fail "/run/current-system not found (not NixOS?)"

RUNNING="$(readlink -f /run/current-system)"

# Generation number and switch time of the system profile, if it points at the running system.
GEN=null
SWITCHED=null
PROFILE_LINK="$(readlink /nix/var/nix/profiles/system 2>/dev/null || true)"
if [[ "$PROFILE_LINK" =~ ^system-([0-9]+)-link$ ]] \
    && [ "$(readlink -f /nix/var/nix/profiles/system)" = "$RUNNING" ]; then
    GEN="${BASH_REMATCH[1]}"
    SWITCHED="$(stat -c %Y "/nix/var/nix/profiles/$PROFILE_LINK" 2>/dev/null || echo null)"
fi

NEW_OUT="$("${NIX[@]}" eval --raw "$FLAKE_DIR#$ATTR.outPath" 2>"$TMPDIR_/err")" \
    || fail "could not evaluate $ATTR"

if [ "$NEW_OUT" = "$RUNNING" ]; then
    "${JQ[@]}" -cn --argjson gen "$GEN" --argjson at "$SWITCHED" \
        '{status: "synced", generation: $gen, switchedAt: $at}'
    exit 0
fi

"${JQ[@]}" -cn \
    --argjson gen "$GEN" --argjson at "$SWITCHED" \
    --arg running "$RUNNING" --arg flake "$NEW_OUT" \
    '{status: "behind", generation: $gen, switchedAt: $at, running: $running, flake: $flake}'
