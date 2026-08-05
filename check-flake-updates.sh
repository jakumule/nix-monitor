#!/usr/bin/env bash
# Checks flakeDirectory (arg 1) for inputs with newer revisions available upstream.
#
# Re-resolves the inputs into a scratch lock file (nix flake update --output-lock-file)
# without touching the real flake.lock, then diffs locked revisions against it. Only the
# top-level inputs declared in flake.nix are reported - transitive inputs (e.g. an input's
# own nixpkgs) are not, even though they're also present in flake.lock. Follows-chains are
# resolved to whatever node they actually point at. Requires
# `nix` (with the flakes/nix-command experimental features available) - that's it. If `jq`
# isn't already on PATH, it's fetched on demand via `nix run nixpkgs#jq` (cached after first
# use) instead of requiring it pre-installed, since `nix` is already a hard requirement for
# the flake-update step.
#
# Prints JSON: {"count": <number>, "inputs": [<outdated input names>]}
# count is -1 to signal an error/unknown state (missing flake, network failure, etc).
set -euo pipefail

NIX=(nix --extra-experimental-features "nix-command flakes")
if command -v jq >/dev/null 2>&1; then
    JQ=(jq)
else
    JQ=("${NIX[@]}" run nixpkgs#jq --)
fi

FLAKE_DIR="${1:-}"

fail() {
    echo '{"count":-1,"inputs":[]}'
    exit 0
}

[ -n "$FLAKE_DIR" ] || fail
[ -f "$FLAKE_DIR/flake.nix" ] || fail
[ -f "$FLAKE_DIR/flake.lock" ] || fail

TMPLOCK="$(mktemp)"
trap 'rm -f "$TMPLOCK"' EXIT

"${NIX[@]}" flake update \
    --flake "$FLAKE_DIR" \
    --output-lock-file "$TMPLOCK" \
    --quiet || fail

"${JQ[@]}" -n \
    --slurpfile old "$FLAKE_DIR/flake.lock" \
    --slurpfile new "$TMPLOCK" \
    'def resolveNode($nodes; $ref):
       if ($ref | type) == "string" then $ref
       else reduce $ref[] as $name ("root"; resolveNode($nodes; $nodes[.].inputs[$name]))
       end;
     ($old[0].nodes) as $o
     | ($new[0].nodes) as $n
     | ($o.root.inputs // {}) as $topInputs
     | [
         $topInputs | keys[] as $name
         | resolveNode($o; $topInputs[$name]) as $key
         | select(($o[$key].locked.rev // null) != null)
         | select(($n[$key].locked.rev // null) != ($o[$key].locked.rev // null))
         | $name
       ] as $outdated
     | {count: ($outdated | length), inputs: $outdated}' \
    || fail
