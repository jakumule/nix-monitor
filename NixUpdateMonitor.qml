import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool checkUpdates: pluginData.checkUpdates !== undefined ? pluginData.checkUpdates : true
    property int updateCheckInterval: pluginData.updateCheckInterval || 3600
    property string nixpkgsChannel: pluginData.nixpkgsChannel || "nixos-unstable"
    property string mode: pluginData.mode || "standard"
    property string flakeDirectory: pluginData.flakeDirectory || "/etc/nixos"

    property string lastUpdate: ""
    property bool operationRunning: false
    property string consoleOutput: ""
    property bool showConsole: false
    property string runningOperation: ""
    property string localRevision: "..."
    property string remoteRevision: "..."
    property bool isUpToDate: true
    property bool canCompareVersions: false
    property bool isCheckingUpdates: false
    property bool checkUpdatesPending: false
    property int pendingCheckProcesses: 0
    property int outdatedInputCount: -1
    property var outdatedInputs: []

    // Every setting - including commands - is sourced from pluginData: either the Settings UI,
    // or a DMS-native declarative plugin install (`programs.dank-material-shell.plugins.<id>.settings`
    // in a flake). There is no separate config file. Commands are plain shell-command strings
    // (run via `bash -c`) rather than argv arrays, so they're editable as a single text field.
    property string localRevisionCommandStr: pluginData.localRevisionCommand || "v=$(nixos-version --hash 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'"
    property string remoteRevisionCommandStr: pluginData.remoteRevisionCommand || ("v=$(git ls-remote https://github.com/NixOS/nixpkgs.git " + root.nixpkgsChannel + " 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'")
    property string flakeUpdateCheckCommandStr: pluginData.flakeUpdateCheckCommand || (root.pluginDir + "/check-flake-updates.sh " + root.flakeDirectory)
    property string flakeUpdateCommandStr: pluginData.flakeUpdateCommand || ("cd " + root.flakeDirectory + " && nix --extra-experimental-features 'nix-command flakes' flake update 2>&1")

    property var localRevisionCommand: ["bash", "-c", root.localRevisionCommandStr]
    property var remoteRevisionCommand: ["bash", "-c", root.remoteRevisionCommandStr]
    property var flakeUpdateCheckCommand: ["bash", "-c", root.flakeUpdateCheckCommandStr]
    property var flakeUpdateCommand: ["bash", "-c", root.flakeUpdateCommandStr]

    // Resolved by DMS at load time regardless of what the plugin's containing folder is
    // actually named (manual clones, "Scan for Plugins", and a declarative `src` don't all
    // agree on casing) - falls back to a best-effort guess if that lookup isn't available yet.
    readonly property string pluginDir: pluginService?.availablePlugins?.[pluginId]?.pluginDirectory
        || (Quickshell.env("HOME") + "/.config/DankMaterialShell/plugins/NixUpdateMonitor")

    Component.onCompleted: {
        console.info("Nix Update Monitor plugin loaded")
        refreshData()
    }

    // pluginData isn't populated yet at Component.onCompleted - DMS loads it asynchronously
    // after the instance is created - so re-run once real settings (if any) arrive.
    onPluginDataChanged: {
        refreshData()
    }

    readonly property bool showOutdatedCount: root.mode === "flake" && root.canCompareVersions && !root.isUpToDate && root.outdatedInputCount > 0

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: "ac_unit"
                size: root.iconSize
                color: root.statusColor()
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.outdatedInputCount + " outdated input" + (root.outdatedInputCount === 1 ? "" : "s")
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showOutdatedCount
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "ac_unit"
                size: root.iconSize
                color: root.statusColor()
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.outdatedInputCount.toString()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.showOutdatedCount
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Nix Update Monitor"
            detailsText: root.lastUpdate ? "Updated: " + root.lastUpdate : "Loading..."
            showCloseButton: true

            Item {
                width: parent.width
                implicitHeight: mainColumn.implicitHeight + Theme.spacingL

                Column {
                    id: mainColumn
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledRect {
                        width: parent.width
                        height: nixpkgsUpdateContent.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh
                        visible: root.checkUpdates

                        Column {
                            id: nixpkgsUpdateContent
                            width: parent.width - Theme.spacingM * 2
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: root.isCheckingUpdates ? "sync" : (root.canCompareVersions ? (root.isUpToDate ? "check_circle" : "update") : "error")
                                    size: Theme.iconSize
                                    color: root.statusColor()
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: {
                                        if (root.isCheckingUpdates) return "Checking for updates..."
                                        if (root.mode === "flake") {
                                            if (!root.canCompareVersions) return "Could not check flake inputs"
                                            if (root.isUpToDate) return "Flake inputs are up to date"
                                            return root.outdatedInputCount + " input" + (root.outdatedInputCount === 1 ? "" : "s") + " can be updated"
                                        }
                                        return root.canCompareVersions ? (root.isUpToDate ? "Nixpkgs is up to date" : "Nixpkgs update available") : "Could not fetch version info"
                                    }
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM
                                visible: root.mode === "standard" && !root.isCheckingUpdates

                                Column {
                                    spacing: Theme.spacingXXS

                                    StyledText {
                                        text: "Local:"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        text: root.localRevision
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: "monospace"
                                        color: Theme.surfaceText
                                    }
                                }

                                Column {
                                    spacing: Theme.spacingXXS

                                    StyledText {
                                        text: "Remote (" + root.nixpkgsChannel + "):"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        text: root.remoteRevision
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: "monospace"
                                        color: Theme.surfaceText
                                    }
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingXXS
                                visible: root.mode === "flake" && !root.isCheckingUpdates

                                Row {
                                    spacing: Theme.spacingXXS

                                    StyledText {
                                        text: "Directory:"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        text: root.flakeDirectory
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: "monospace"
                                        color: Theme.surfaceText
                                    }
                                }

                                Column {
                                    width: parent.width
                                    spacing: Theme.spacingXXS
                                    visible: root.outdatedInputs.length > 0

                                    StyledText {
                                        text: "Outdated:"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    Repeater {
                                        model: root.outdatedInputs

                                        StyledText {
                                            width: parent.width
                                            text: "  " + modelData
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.family: "monospace"
                                            color: Theme.surfaceText
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: "Actions"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            DankButton {
                                width: root.mode === "flake" ? (parent.width - Theme.spacingS) / 2 : parent.width
                                text: "Refresh"
                                iconName: "refresh"
                                enabled: !root.isCheckingUpdates && !root.operationRunning
                                onClicked: {
                                    root.refreshData()
                                }
                            }

                            DankButton {
                                width: (parent.width - Theme.spacingS) / 2
                                visible: root.mode === "flake"
                                text: root.operationRunning && root.runningOperation === "flakeUpdate" ? "Updating..." : "Update Flake Inputs"
                                iconName: "system_update"
                                backgroundColor: Theme.secondary
                                textColor: Theme.onSecondary
                                enabled: !root.operationRunning
                                onClicked: {
                                    root.updateFlakeInputs()
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: root.showConsole

                        StyledText {
                            text: "Console Output"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }

                        StyledRect {
                            width: parent.width
                            height: 200
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerLow

                            Flickable {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                contentHeight: outputText.implicitHeight
                                clip: true

                                StyledText {
                                    id: outputText
                                    width: parent.width
                                    text: root.consoleOutput || "Waiting for output..."
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.family: "monospace"
                                    color: Theme.surfaceText
                                    wrapMode: Text.Wrap
                                }

                                onContentHeightChanged: {
                                    if (contentHeight > height) {
                                        contentY = contentHeight - height
                                    }
                                }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width - clearButton.width - cancelButton.width - Theme.spacingS * 2
                                height: 1
                            }

                            DankButton {
                                id: cancelButton
                                text: "Cancel"
                                iconName: "cancel"
                                buttonHeight: 30
                                backgroundColor: Theme.error
                                textColor: Theme.onError
                                opacity: root.operationRunning ? 1 : 0
                                enabled: root.operationRunning
                                onClicked: {
                                    root.cancelOperation()
                                }
                            }

                            DankButton {
                                id: clearButton
                                text: "Clear"
                                iconName: "close"
                                buttonHeight: 30
                                enabled: !root.operationRunning
                                onClicked: {
                                    root.showConsole = false
                                    root.consoleOutput = ""
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 450
    popoutHeight: 400

    Timer {
        id: updateCheckTimer
        interval: root.updateCheckInterval * 1000
        running: root.checkUpdates
        repeat: true
        onTriggered: root.checkForUpdates()
    }

    Process {
        id: localRevisionProcess
        command: root.localRevisionCommand
        running: false

        stdout: SplitParser {
            onRead: function(line) {
                var revision = line.trim()
                if (revision && revision !== "N/A") {
                    root.localRevision = revision
                } else {
                    root.localRevision = "N/A"
                }
            }
        }

        onExited: function(exitCode, exitStatus) {
            root.updateUpToDateStatus()
            root.onCheckProcessFinished()
        }
    }

    Process {
        id: remoteRevisionProcess
        command: root.remoteRevisionCommand
        running: false

        stdout: SplitParser {
            onRead: function(line) {
                var revision = line.trim()
                if (revision && revision !== "N/A") {
                    root.remoteRevision = revision
                } else {
                    root.remoteRevision = "N/A"
                }
            }
        }

        onExited: function(exitCode, exitStatus) {
            root.updateUpToDateStatus()
            root.onCheckProcessFinished()
        }
    }

    Process {
        id: flakeUpdateCheckProcess
        command: root.flakeUpdateCheckCommand
        running: false
        property string output: ""

        stdout: SplitParser {
            onRead: function(line) {
                flakeUpdateCheckProcess.output += line
            }
        }

        onExited: function(exitCode, exitStatus) {
            var result = null
            try {
                result = JSON.parse(flakeUpdateCheckProcess.output)
            } catch (e) {
                console.warn("Failed to parse flake update check output:", e)
            }
            flakeUpdateCheckProcess.output = ""

            if (result && typeof result.count === "number") {
                root.outdatedInputCount = result.count
                root.outdatedInputs = result.inputs || []
            } else {
                root.outdatedInputCount = -1
                root.outdatedInputs = []
            }

            if (root.outdatedInputCount >= 0) {
                root.canCompareVersions = true
                root.isUpToDate = root.outdatedInputCount === 0
            } else {
                root.canCompareVersions = false
                root.isUpToDate = false
            }

            root.onCheckProcessFinished()
        }
    }

    Process {
        id: flakeUpdateProcess
        command: root.flakeUpdateCommand
        running: false

        stdout: SplitParser {
            onRead: function(line) {
                root.consoleOutput += line + "\n"
            }
        }

        stderr: SplitParser {
            onRead: function(line) {
                root.consoleOutput += line + "\n"
            }
        }

        onExited: function(exitCode, exitStatus) {
            root.operationRunning = false
            root.runningOperation = ""
            if (exitCode === 0) {
                root.consoleOutput += "\n✓ Flake inputs updated\n"
                ToastService.showInfo("Flake inputs updated")
                root.checkForUpdates()
            } else if (exitCode === 143 || exitCode === 130) {
                root.consoleOutput += "\n✗ Update cancelled by user\n"
                ToastService.showInfo("Update cancelled")
            } else {
                root.consoleOutput += "\n✗ Flake update failed (exit code: " + exitCode + ")\n"
                ToastService.showError("Flake update failed")
            }
        }
    }

    // green = up to date, blue = checking, orange = update available, red = error/unknown.
    // Theme.primary (neutral) only applies when update checking is disabled entirely.
    function statusColor() {
        if (!root.checkUpdates) return Theme.primary
        if (root.isCheckingUpdates) return Theme.info
        if (!root.canCompareVersions) return Theme.error
        return root.isUpToDate ? Theme.success : Theme.warning
    }

    function refreshData() {
        if (root.checkUpdates) {
            root.checkForUpdates()
        } else {
            root.lastUpdate = Qt.formatTime(new Date(), "HH:mm:ss")
        }
    }

    function checkForUpdates() {
        // pluginData isn't populated yet when Component.onCompleted fires (see
        // onPluginDataChanged above), so a check can legitimately start with stale/default
        // settings and need to be redone once real settings arrive shortly after. Rather than
        // silently dropping that request when one's already in flight, queue a single retry -
        // otherwise the display gets stuck on the first (wrong-config) result until the next
        // scheduled check or a manual Refresh.
        if (root.isCheckingUpdates) {
            root.checkUpdatesPending = true
            return
        }
        root.checkUpdatesPending = false
        root.isCheckingUpdates = true
        if (root.mode === "flake") {
            root.pendingCheckProcesses = 1
            flakeUpdateCheckProcess.output = ""
            flakeUpdateCheckProcess.running = true
        } else {
            root.pendingCheckProcesses = 2
            localRevisionProcess.running = true
            remoteRevisionProcess.running = true
        }
    }

    // Called by each update-check Process's onExited (standard mode runs two in parallel, so
    // this only closes out the round - and retries if one was queued - once all of them are done.
    function onCheckProcessFinished() {
        root.pendingCheckProcesses -= 1
        if (root.pendingCheckProcesses > 0) return
        root.isCheckingUpdates = false
        root.lastUpdate = Qt.formatTime(new Date(), "HH:mm:ss")
        if (root.checkUpdatesPending) {
            root.checkForUpdates()
        }
    }

    function updateUpToDateStatus() {
        if (root.localRevision !== "..." && root.remoteRevision !== "..." &&
            root.localRevision !== "N/A" && root.remoteRevision !== "N/A") {
            root.canCompareVersions = true
            root.isUpToDate = (root.localRevision === root.remoteRevision)
        } else {
            root.canCompareVersions = false
            root.isUpToDate = false
        }
    }

    function updateFlakeInputs() {
        root.operationRunning = true
        root.runningOperation = "flakeUpdate"
        root.showConsole = true
        root.consoleOutput = "Updating flake inputs...\n"
        ToastService.showInfo("Updating flake inputs...")
        flakeUpdateProcess.running = true
    }

    function cancelOperation() {
        if (root.runningOperation === "flakeUpdate" && flakeUpdateProcess.running) {
            flakeUpdateProcess.running = false
            root.consoleOutput += "\n✗ Cancelling flake update...\n"
        }
        ToastService.showInfo("Cancelling operation...")
    }
}
