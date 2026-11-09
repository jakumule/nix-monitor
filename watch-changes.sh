#!/usr/bin/env bash
# Long-running filesystem watcher (inotify) the plugin uses to run its checks when something
# actually changes, instead of polling. Two modes, one process each:
#
#   watch-changes.sh system [<link>]
#       Watches for the running-system symlink (default /run/current-system) being replaced,
#       i.e. a switch. Prints the link path, one line per replacement.
#
#   watch-changes.sh flake <flakeDirectory>
#       Watches the flake's working tree recursively. Prints the path of each file that was
#       written, created, deleted or renamed, one per line. VCS metadata (.git, .jj), .direnv,
#       `result` build links and editor swap/backup/lock files are ignored - so a file only
#       becoming tracked (`git add`) is not an event by itself.
#
# Once the watches are in place inotifywait prints "Watches established." on stderr; the plugin
# waits for that line before relying on the watcher. Exits non-zero if the target is missing
# or the watches can't be set up (e.g. fs.inotify.max_user_watches exhausted) - the plugin
# then falls back to its timers.
#
# `inotifywait` (inotify-tools) is used from PATH if present, otherwise fetched via
# `nix shell nixpkgs#inotify-tools`. It is exec'ed, so terminating this process stops the watch.
set -euo pipefail

if command -v inotifywait >/dev/null 2>&1; then
    INOTIFYWAIT=(inotifywait)
else
    INOTIFYWAIT=(nix --extra-experimental-features "nix-command flakes"
        shell nixpkgs#inotify-tools -c inotifywait)
fi

MODE="${1:-}"
TARGET="${2:-}"

case "$MODE" in
    system)
        LINK="${TARGET:-/run/current-system}"
        DIR="$(dirname "$LINK")"
        [ -d "$DIR" ] || { echo "$DIR not found" >&2; exit 1; }
        # The link is replaced atomically (created under a temp name, renamed over the old
        # one), so watch its directory and keep only events for the link's own name.
        # --include is a regex: escape the path.
        PATTERN="^$(printf '%s' "$LINK" | sed 's/[][\.*^$+?(){}|/]/\\&/g')\$"
        exec "${INOTIFYWAIT[@]}" -m -e create -e moved_to \
            --include "$PATTERN" --format '%w%f' "$DIR"
        ;;
    flake)
        # "~" is not expanded when the directory arrives as a plain argument.
        case "$TARGET" in
            "~") TARGET="$HOME" ;;
            "~/"*) TARGET="$HOME/${TARGET#"~/"}" ;;
        esac
        [ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "flake directory '$TARGET' not found" >&2; exit 1; }
        # Resolve symlinks: inotifywait does not follow a symlinked root when recursing.
        TARGET="$(readlink -f "$TARGET")"
        exec "${INOTIFYWAIT[@]}" -m -r \
            -e close_write -e create -e delete -e moved_to -e moved_from \
            --exclude '/(\.git|\.jj|\.direnv|result(-[^/]*)?)(/|$)|(\.sw[a-z]|\.swpx|~|\.tmp|\.bak|\.orig)$|/(4913|\.#[^/]*|#[^/]*#|\.~lock\.[^/]*)$' \
            --format '%w%f' "$TARGET"
        ;;
    *)
        echo "usage: $0 system [<link>] | flake <flakeDirectory>" >&2
        exit 2
        ;;
esac
