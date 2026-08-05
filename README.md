# Nix Update Monitor

![](./assets/scrot.png)

A [DankMaterialShell](https://danklinux.com/) plugin for monitoring nixpkgs/flake input updates.

> **Note:** Nix store size, system generation count, and the Rebuild/GC action buttons used to be
> here too. That logic has been stripped out for now (it may come back later) - this is purely an
> update monitor at the moment.

## Features

### Two Monitor Modes
- **Standard mode** - Normal NixOS/channel behavior: compares your local nixpkgs revision against a channel branch (e.g. `nixos-unstable`) via `git ls-remote`
- **Flake mode** - For flake-based configurations: checks `flake.lock` at a configured directory for inputs that have newer revisions available upstream, and lists which inputs are outdated

### Bar Widget Display
- Update status - Check icon shows update status for the active mode:
  - Green: Up-to-date (nixpkgs, or all flake inputs)
  - Yellow: Update available (nixpkgs, or one or more flake inputs outdated)
  - Red: Could not fetch version info / could not check flake inputs

### Detailed Popout Panel
Click the widget to open a detailed view with:
- Update status - In standard mode, shows local and remote nixpkgs revisions; in flake mode, shows the flake directory and the list of outdated inputs
- Real-time console - View command output as it runs (flake mode)
- Action buttons:
  - Refresh - Re-run the update check immediately
  - Update Flake Inputs - (flake mode only) Run `nix flake update` on your flake directory
  - Cancel - Stop running operation
- Clear button - Hide console output

### Configurable Settings
Access via DMS Settings → Plugins → Nix Update Monitor - every setting is editable here,
including commands - see "Configuration" below:
- Enable/disable update checking
- Monitor mode - Standard or Flake
- NixOS channel selection (unstable, 25.11, 25.05, 24.11) - standard mode
- Flake directory - flake mode
- Update check interval (300-86400 seconds)
- Revision-check and flake-update commands

## Installation

This plugin has no Nix module of its own - it's installed and configured entirely through
DankMaterialShell's own plugin system (`programs.dank-material-shell.plugins`), the same
mechanism used for registry plugins like `dockerManager`. **This requires the home-manager
module** - DMS's NixOS module does not support declarative plugin `settings` (you can still
install the plugin under the NixOS module, but you'd have to configure it by hand afterwards
in DMS Settings → Plugins instead of declaratively).

### 1. Wire it into `programs.dank-material-shell.plugins`

Alongside wherever you already import `dms.homeModules.dank-material-shell`:

```nix
{ pkgs, ... }:
{
  programs.dank-material-shell = {
    enable = true;

    plugins = {
      nixUpdateMonitor = {
        src = pkgs.fetchFromGitHub {
          owner = "JacquesHumule";
          repo = "dms-nix-update-monitor";
          rev = "v1.0.0";
          sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
        settings = {
          # All optional - see "Configuration" below for the full list
          mode = "flake";
          flakeDirectory = "/etc/nixos";
        };
      };

      # other plugins, e.g. from the registry:
      dockerManager.enable = true;
    };
  };
}
```

Get the real `sha256` by setting it to `pkgs.lib.fakeSha256` first, rebuilding, and copying the
"got: sha256-..." value Nix prints in the mismatch error - or with `nix-prefetch-github
JacquesHumule dms-nix-update-monitor --rev v1.0.0` if you have `nix-prefetch-github` available.

`settings` writes directly into the same `plugin_settings.json` store the in-app Settings UI
reads and writes - so anything declared there shows up as the current value in Settings →
Plugins → Nix Update Monitor, and anything left undeclared is freely user-editable there
instead (see "Configuration" below for which is which).

### 2. Activate

1. Rebuild: `home-manager switch --flake .#home` (or your usual rebuild command)
2. Clear the QML cache and restart DMS: `rm -rf ~/.cache/quickshell/qmlcache/ && dms restart`
3. Add the widget to your DankBar layout

### Updating

Bump `rev` (and `sha256` - see above) to the new release, then:

```bash
home-manager switch --flake .#home
rm -rf ~/.cache/quickshell/qmlcache/
dms restart
```

**Note:** Due to QML disk caching, you must clear the QML cache after plugin updates for
changes to take effect.

## Usage

### Bar Widget
- The widget shows in your DankBar with an icon and an update-status check mark
- Click to open the detailed popout panel

### Popout Panel
- Refresh - Re-runs the update check immediately
- Update Flake Inputs - (flake mode only) Runs your configured flake-update command

### Console Output
- Appears automatically when running Update Flake Inputs
- Shows real-time stdout/stderr
- Auto-scrolls to latest output
- Click "Clear" to hide

## Configuration

There's a single settings store (`pluginData`) behind everything - the in-app Settings UI and a
declarative `settings = {...}` block both read and write the exact same keys, and **everything is
editable from either side**, including commands. Two ways to set them:

- **In DMS Settings → Plugins → Nix Update Monitor** - for anything you want to tweak at
  runtime without a rebuild.
- **Declaratively**, via `programs.dank-material-shell.plugins.nixUpdateMonitor.settings` in
  your flake - for anything you want reproducible across rebuilds. Declared values show up as
  the current value in the Settings UI too.

Commands are plain shell-command strings (run via `bash -c`, so pipes/`&&`/redirects all work
as-is) rather than argv arrays - one line, whether you're typing it into a text field or a Nix
string.

### Zero-config

Everything works out of the box in standard mode - no settings are required at all:

```nix
settings = { };
```

### Flake mode, full example

```nix
settings = {
  mode = "flake";
  flakeDirectory = "/etc/nixos"; # must already build via `nix flake update`/`nixos-rebuild --flake` as-is

  updateCheckInterval = 3600; # update-check refresh, seconds
};
```

This adds an "Update Flake Inputs" button (running `nix flake update` in `flakeDirectory`) and
shows which inputs have newer revisions available, instead of comparing a single nixpkgs revision
against a channel. The check itself (`check-flake-updates.sh`, shipped with the plugin) re-resolves
`flakeDirectory`'s inputs into a scratch lock file (`nix flake update --output-lock-file <scratch>`)
and diffs it against the real `flake.lock` - the real lock file is never written to. Only the
top-level inputs declared in your `flake.nix` are reported (e.g. `nixpkgs`, `home-manager`) -
transitive inputs (e.g. `home-manager`'s own `nixpkgs`) are not listed separately, even though
they're also present in `flake.lock`.

### Non-NixOS (Fedora + Nix, etc.)

Nothing here is actually NixOS-specific except one default - everything else is just shell
commands against `nix` itself, which work the same on any Nix install:

```nix
settings = {
  # standard mode's default localRevisionCommand shells out to `nixos-version`, which doesn't
  # exist off NixOS - either switch to flake mode (recommended, since it needs nothing
  # NixOS-specific) or override localRevisionCommand/remoteRevisionCommand yourself.
  mode = "flake";
  flakeDirectory = "~/.config/home-manager";
};
```

### All settings

**Commands** (plain shell-command strings, run via `bash -c`; all default to plain PATH lookups -
embed absolute `${pkgs.x}/bin/y` paths in the string from your flake if you want a specific one
Nix-pinned):
- `localRevisionCommand` - local nixpkgs revision (standard mode). Default: `v=$(nixos-version --hash | cut -c 1-7); [ -n "$v" ] && echo "$v" || echo 'N/A'`. **NixOS-only** (`nixos-version` isn't available elsewhere) - falls back to "N/A" if missing; see "Non-NixOS" below.
- `remoteRevisionCommand` - remote nixpkgs revision (standard mode). Default: `v=$(git ls-remote https://github.com/NixOS/nixpkgs.git <nixpkgsChannel> | cut -c 1-7); [ -n "$v" ] && echo "$v" || echo 'N/A'` (auto-follows whatever `nixpkgsChannel` is set to, unless you override this explicitly).
  **Performance tip:** use curl against GitHub's API instead:
  ```nix
  remoteRevisionCommand =
    "${pkgs.curl}/bin/curl -s https://api.github.com/repos/NixOS/nixpkgs/git/ref/heads/nixos-unstable 2>/dev/null | ${pkgs.jq}/bin/jq -r '.object.sha' 2>/dev/null | cut -c 1-7 || echo 'N/A'";
  ```
- `flakeUpdateCheckCommand` - flake-mode input check. `settings`-only, no UI field (the bundled `check-flake-updates.sh` is always used unless you override this declaratively). Default: `<plugin dir>/check-flake-updates.sh <flakeDirectory>`. Must print JSON `{"count": <number>, "inputs": [<names>]}` (`count: -1` signals an error/unknown state).
- `flakeUpdateCommand` - flake-mode "Update Flake Inputs" button. Default: `cd <flakeDirectory> && nix flake update`

**Preferences**:
- `checkUpdates` (bool, default `true`) - enable/disable update checking entirely
- `updateCheckInterval` (int, default `3600`) - update-check interval, seconds
- `mode` (`"standard"` | `"flake"`, default `"standard"`)
- `nixpkgsChannel` (default `"nixos-unstable"`, standard mode only)
- `flakeDirectory` (default `"/etc/nixos"`, flake mode only)

## Requirements

- DankMaterialShell >= 1.0.0
- Nix package manager
- `jq` - only needed for flake mode; auto-fetched via `nix run nixpkgs#jq` if not already on `PATH` (adds first-run latency and a dependency on the `nixpkgs` flake registry entry - install it normally, e.g. via `home.packages`, to avoid both)
- `git` (for standard-mode update checking, and because flake mode requires `flakeDirectory` to already be a git-tracked flake source, same as `nixos-rebuild --flake` does)

## License

MIT

## Author

Jacques Rathier ([@jacqueshumule](https://github.com/jacqueshumule))

Based on [nix-monitor](https://github.com/antonjah/nix-monitor) by Anton Andersson.
