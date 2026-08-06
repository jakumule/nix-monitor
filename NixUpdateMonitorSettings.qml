import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.DCommon.Widgets

PluginSettings {
    id: root
    pluginId: "nixUpdateMonitor"

    StyledText {
        width: parent.width
        text: "Nix Update Monitor Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Configure nixpkgs/flake-input update checking"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: "NixOS Update Checking"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingM
    }

    ToggleSetting {
        settingKey: "checkUpdates"
        label: "Check for Updates"
        description: "Monitor nixpkgs for available updates"
        defaultValue: true
    }

    SelectionSetting {
        id: modeSetting
        settingKey: "mode"
        label: "Monitor Mode"
        description: "Standard compares nixpkgs against a channel; Flake checks flake.lock inputs for updates"
        defaultValue: "standard"
        options: [
            { value: "standard", label: "Standard" },
            { value: "flake", label: "Flake" }
        ]
    }

    SelectionSetting {
        settingKey: "nixpkgsChannel"
        label: "NixOS Channel"
        description: "Which channel to check for updates"
        defaultValue: "nixos-unstable"
        visible: modeSetting.value === "standard"
        options: [
            { value: "nixos-unstable", label: "nixos-unstable" },
            { value: "nixos-25.11", label: "nixos-25.11" },
            { value: "nixos-25.05", label: "nixos-25.05" },
            { value: "nixos-24.11", label: "nixos-24.11" }
        ]
    }

    StringSetting {
        settingKey: "localRevisionCommand"
        label: "Local Revision Command"
        description: "Gets your local nixpkgs revision (stdout like \"a1b2c3d\" or \"N/A\"). Default uses `nixos-version`, which only exists on NixOS - on other Nix-enabled distros (e.g. Fedora + Nix), override this."
        defaultValue: "v=$(nixos-version --hash 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'"
        placeholder: "v=$(nixos-version --hash 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'"
        visible: modeSetting.value === "standard"
    }

    StringSetting {
        settingKey: "remoteRevisionCommand"
        label: "Remote Revision Command"
        description: "Gets the latest revision on NixOS Channel above. Leave blank to auto-follow whatever channel is selected."
        defaultValue: ""
        placeholder: "v=$(git ls-remote https://github.com/NixOS/nixpkgs.git nixos-unstable 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'"
        visible: modeSetting.value === "standard"
    }

    StringSetting {
        settingKey: "flakeDirectory"
        label: "Flake Directory"
        description: "Directory containing flake.nix and flake.lock to check for input updates"
        defaultValue: "/etc/nixos"
        placeholder: "/etc/nixos"
        visible: modeSetting.value === "flake"
    }

    ToggleSetting {
        settingKey: "autoDiff"
        label: "Compute Package Changes Automatically"
        description: "Evaluate the flake with all inputs updated and diff it with dix against the running system - what an update + rebuild would change, even when flake.lock is current. Re-runs when upstream or the running system changes, or on Refresh (one evaluation, ~20-40 s of CPU)."
        defaultValue: true
        visible: modeSetting.value === "flake"
    }

    ToggleSetting {
        settingKey: "checkSystem"
        label: "Check Running System"
        description: "Separately from the inputs, check whether /run/current-system is what the flake (working tree, uncommitted edits included) currently evaluates to - i.e. whether a rebuild is pending. One evaluation per check (~15 s). Re-checks automatically after a switch."
        defaultValue: true
        visible: modeSetting.value === "flake"
    }

    StringSetting {
        settingKey: "flakeOutputAttr"
        label: "Flake Output Attribute"
        description: "Derivation diffed for package changes and compared against the running system. Leave blank for this host's NixOS system. Examples: homeConfigurations.me.activationPackage, darwinConfigurations.mac.system"
        defaultValue: ""
        placeholder: "nixosConfigurations.<hostname>.config.system.build.toplevel"
        visible: modeSetting.value === "flake"
    }


    SliderSetting {
        settingKey: "updateCheckInterval"
        label: "Update Check Interval"
        description: "How often to check for nixpkgs updates"
        defaultValue: 3600
        minimum: 300
        maximum: 86400
        unit: "sec"
    }
}
