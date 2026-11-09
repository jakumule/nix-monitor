import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool checkUpdates: pluginData.checkUpdates !== undefined ? pluginData.checkUpdates : true
    property int updateCheckInterval: pluginData.updateCheckInterval || 3600
    property string nixpkgsChannel: pluginData.nixpkgsChannel || "nixos-unstable"
    property string mode: pluginData.mode || "standard"
    property string flakeDirectory: pluginData.flakeDirectory || "/etc/nixos"
    property string flakeOutputAttr: pluginData.flakeOutputAttr || ""
    property bool autoDiff: pluginData.autoDiff !== undefined ? pluginData.autoDiff : true
    property bool checkSystem: pluginData.checkSystem !== undefined ? pluginData.checkSystem : true
    property bool watchFiles: pluginData.watchFiles !== undefined ? pluginData.watchFiles : true

    property string lastUpdate: ""

    property string localRevision: "..."
    property string remoteRevision: "..."
    property bool isUpToDate: true
    property bool canCompareVersions: false
    property bool isCheckingUpdates: false
    property bool checkUpdatesPending: false
    property int pendingCheckProcesses: 0
    property bool inputsChecked: false // a flake-input check has finished at least once
    property int outdatedInputCount: -1
    property var outdatedInputs: []
    // [{name, oldRev, newRev, oldDate, newDate}] - only filled when the check command reports
    // "details" (the bundled one does); custom commands may only report names.
    property var inputDetails: []

    // dix diff of the running system vs. the flake evaluated with fully updated inputs (see
    // diff-flake-update.sh): what `nix flake update` + rebuild would change. Computed even when
    // flake.lock is current (a rebuild can still be pending). A full evaluation, so it only
    // re-runs when the updated lock or the running system changes (diffKey) - or on a manual
    // Refresh, which also catches local config edits.
    property var diffResult: null      // parsed JSON with status "ok" | "same"
    property string diffError: ""
    property bool isComputingDiff: false
    property string diffKey: ""        // key the current diffResult/diffError belongs to
    property string runningDiffKey: "" // key of the diff process currently running
    property string queuedDiffKey: ""  // newer key requested while one was running
    property string lastDiffTime: ""
    property bool autoDiffDeferred: false // auto diff waits for a running system check
    property bool forceDiff: false        // next auto diff recomputes even if the key is unchanged
    property string lockHash: ""          // fingerprint of the updated lock (check-flake-updates.sh)

    // Running system vs. what the flake evaluates to now (see check-system-sync.sh). This is
    // a separate question from "is flake.lock behind upstream": the lock can be current while
    // the system was never rebuilt from it (or from local config edits).
    property var systemResult: null    // parsed JSON with status "synced" | "behind"
    property string systemError: ""
    property bool systemCheckPending: false
    property string lastSystemCheck: ""
    property string runningSystemPath: "" // last seen /run/current-system target

    // Filesystem watchers (see watch-changes.sh): a switch and edits to the flake's working
    // tree trigger the matching checks right away. "Ready" = inotify watches are in place;
    // until then (or if a watcher can't run) the timers below are all there is.
    property bool systemWatchReady: false
    property bool flakeWatchReady: false
    property bool flakeWatchRestart: false  // restart the watcher once it has exited
    property bool systemWatchRestart: false
    property bool pendingInputsChange: false // flake.lock / flake.nix changed (debounced)
    property bool pendingTreeChange: false   // some other file in the flake changed (debounced)

    // Every setting - including commands - is sourced from pluginData: either the Settings UI,
    // or a DMS-native declarative plugin install (`programs.dank-material-shell.plugins.<id>.settings`
    // in a flake). There is no separate config file. Commands are plain shell-command strings
    // (run via `bash -c`) rather than argv arrays, so they're editable as a single text field.
    property string localRevisionCommandStr: pluginData.localRevisionCommand || "v=$(nixos-version --hash 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'"
    property string remoteRevisionCommandStr: pluginData.remoteRevisionCommand || ("v=$(git ls-remote https://github.com/NixOS/nixpkgs.git " + root.nixpkgsChannel + " 2>/dev/null | cut -c 1-7); [ -n \"$v\" ] && echo \"$v\" || echo 'N/A'")
    property string flakeUpdateCheckCommandStr: pluginData.flakeUpdateCheckCommand || (root.pluginDir + "/check-flake-updates.sh " + root.flakeDirectory)
    // Unlike the commands above, the defaults are passed as argv (not bash -c) so the flake
    // directory and attribute need no shell quoting.
    property var diffCommand: pluginData.diffCommand
        ? ["bash", "-c", pluginData.diffCommand]
        : [root.pluginDir + "/diff-flake-update.sh", root.flakeDirectory, root.flakeOutputAttr, ""]
    property var systemCheckCommand: pluginData.systemCheckCommand
        ? ["bash", "-c", pluginData.systemCheckCommand]
        : [root.pluginDir + "/check-system-sync.sh", root.flakeDirectory, root.flakeOutputAttr]

    property var localRevisionCommand: ["bash", "-c", root.localRevisionCommandStr]
    property var remoteRevisionCommand: ["bash", "-c", root.remoteRevisionCommandStr]
    property var flakeUpdateCheckCommand: ["bash", "-c", root.flakeUpdateCheckCommandStr]

    // Resolved by DMS at load time regardless of what the plugin's containing folder is
    // actually named (manual clones, "Scan for Plugins", and a declarative `src` don't all
    // agree on casing) - falls back to a best-effort guess if that lookup isn't available yet.
    readonly property string pluginDir: pluginService?.availablePlugins?.[pluginId]?.pluginDirectory
        || (Quickshell.env("HOME") + "/.config/DankMaterialShell/plugins/NixUpdateMonitor")

    // ---- Derived view state ------------------------------------------------------------

    readonly property bool isFlake: root.mode === "flake"
    readonly property bool watchEnabled: root.isFlake && root.checkUpdates && root.watchFiles
    // The same directory the checks use, as an argv (no shell quoting needed).
    readonly property var flakeWatchCommand: [root.pluginDir + "/watch-changes.sh", "flake", root.flakeDirectory]
    readonly property var systemWatchCommand: [root.pluginDir + "/watch-changes.sh", "system"]
    readonly property bool showOutdatedCount: root.isFlake && root.canCompareVersions && !root.isUpToDate && root.outdatedInputCount > 0
    readonly property bool hasPackageDiff: root.diffResult !== null && root.diffResult.status === "ok"
    readonly property var diffCounts: root.hasPackageDiff ? root.diffResult.counts : ({ upgraded: 0, downgraded: 0, added: 0, removed: 0 })
    // True while the shown diff belongs to an older set of input revisions than the current one.
    readonly property bool diffOutdated: root.diffKey !== "" && root.diffKey !== root.currentDiffKey()

    // The running-system comparison only makes sense for a NixOS system output.
    readonly property bool systemCheckEnabled: root.isFlake && root.checkUpdates && root.checkSystem
        && (root.flakeOutputAttr === "" || root.flakeOutputAttr.indexOf("nixosConfigurations.") === 0)
    readonly property bool inputsChecking: root.isFlake && root.isCheckingUpdates
    readonly property bool systemChecking: systemSyncProcess.running

    // Per-link state of the pipeline upstream → flake.lock → running system:
    // "unknown" (no result yet) | "synced" | "behind" | "error" | "off".
    readonly property string inputsState: !root.inputsChecked ? "unknown"
        : root.outdatedInputCount < 0 ? "error"
        : root.outdatedInputCount === 0 ? "synced" : "behind"
    readonly property string systemState: !root.systemCheckEnabled ? "off"
        : root.systemError ? "error"
        : root.systemResult ? root.systemResult.status : "unknown"
    readonly property string overallState: {
        var s = [root.inputsState, root.systemState]
        if (s.indexOf("error") !== -1) return "error"
        if (s.indexOf("behind") !== -1) return "behind"
        if (s.indexOf("unknown") !== -1) return "unknown"
        return "synced"
    }
    readonly property bool showSystemBadge: root.systemState === "behind" || root.systemState === "error"

    // The package diff shown in the popout (running system → updated flake).
    readonly property var activeDiff: root.hasPackageDiff ? root.diffResult : null
    readonly property var activeCounts: root.activeDiff ? root.activeDiff.counts : ({ upgraded: 0, downgraded: 0, added: 0, removed: 0 })
    readonly property int activeTotal: root.activeDiff ? root.activeDiff.packages.length : 0

    // Popout state: a filter chip narrows the package list to one status ("" = all) and the
    // search filters by package name.
    readonly property var sectionOrder: ["upgraded", "added", "removed", "downgraded"]
    property string statusFilter: ""
    property string packageSearch: ""
    property bool showAllInputs: false
    readonly property int inputRowLimit: 3
    readonly property int packageRowHeight: 30
    // The popout is sized by its content, so the list is what has to give on a short screen
    // (or when the inputs list is expanded): 3-10 rows out of what the rest leaves over.
    readonly property int packageListMaxHeight: {
        var extraInputs = root.showAllInputs ? Math.max(0, root.inputRows().length - root.inputRowLimit) : 0
        var room = (root.parentScreen?.height ?? 1080) - 680 - extraInputs * 40
        return Math.max(3, Math.min(10, Math.floor(room / root.packageRowHeight))) * root.packageRowHeight
    }

    // "All" plus one chip per status that actually occurs in the diff. Kept to icon + count
    // (status name in the tooltip) so the five of them fit on one row.
    readonly property var filterChips: {
        var chips = [{ label: "All " + root.activeTotal, value: "" }]
        for (var i = 0; i < root.sectionOrder.length; i++) {
            var status = root.sectionOrder[i]
            var n = root.activeCounts[status] || 0
            if (n > 0) chips.push({
                label: String(n), value: status, icon: root.packageStatusIcon(status),
                tooltip: status.charAt(0).toUpperCase() + status.slice(1)
            })
        }
        return chips
    }
    // statusFilter, unless a newer diff no longer has any package of that status.
    readonly property string activeFilter: (root.activeCounts[root.statusFilter] || 0) > 0 ? root.statusFilter : ""
    readonly property int filterIndex: {
        for (var i = 0; i < root.filterChips.length; i++)
            if (root.filterChips[i].value === root.activeFilter) return i
        return 0
    }

    // Rows of the package list: grouped by status (sectionOrder), by name within a status.
    readonly property var packageRows: {
        if (!root.activeDiff) return []
        var q = root.packageSearch.trim().toLowerCase()
        var rows = []
        for (var i = 0; i < root.sectionOrder.length; i++) {
            var status = root.sectionOrder[i]
            if (root.activeFilter && root.activeFilter !== status) continue
            var pkgs = root.activeDiff.packages.filter(function(p) {
                return p.status === status && (!q || p.name.toLowerCase().indexOf(q) !== -1)
            })
            pkgs.sort(function(a, b) { return a.name.localeCompare(b.name) })
            for (var j = 0; j < pkgs.length; j++)
                rows.push({ status: status, name: pkgs[j].name, changes: pkgs[j].changes })
        }
        return rows
    }

    // What the package-changes section shows in place of the list (see diffPanel).
    readonly property var diffState: {
        var dir = root.shortenHome(root.flakeDirectory)
        if (root.inputsState === "error")
            return { kind: "inputsError", icon: "error", color: Theme.error, isError: true,
                     title: "Could not check flake inputs",
                     text: "Make sure " + dir + " contains flake.nix and flake.lock." }
        if (root.diffResult !== null && root.diffResult.status === "same")
            return { kind: "same", icon: "check_circle", color: Theme.success, isError: false,
                     title: "Nothing to update",
                     text: "Your running system already matches the flake with the latest inputs." }
        if (root.inputsState === "unknown" && root.diffResult === null && !root.isComputingDiff)
            return { kind: "waiting", icon: "sync", color: Theme.info, isError: false,
                     title: "Resolving inputs",
                     text: "Resolving the latest revisions of your inputs." }
        if (root.isComputingDiff)
            return { kind: "computing", icon: "", color: Theme.surfaceVariantText, isError: false,
                     title: "Computing changes...",
                     text: "Evaluating the flake with the latest inputs and comparing it with the running system (~30 s)" }
        if (root.diffError)
            return { kind: "failed", icon: "error", color: Theme.error, isError: true,
                     title: "Package diff failed", text: root.diffError }
        if (root.diffResult !== null)
            return { kind: "empty", icon: "tune", color: Theme.surfaceVariantText, isError: false,
                     title: "No package changes",
                     text: "Only build inputs or configuration differ - a rebuild still applies them." }
        return { kind: "off", icon: "difference", color: Theme.surfaceVariantText, isError: false,
                 title: "Package changes not computed", text: "Automatic diff is off in settings." }
    }

    Component.onCompleted: {
        console.info("Nix Update Monitor plugin loaded")
        refreshData()
        Qt.callLater(root.restartFlakeWatch)
        Qt.callLater(root.restartSystemWatch)
    }

    // pluginData isn't populated yet at Component.onCompleted - DMS loads it asynchronously
    // after the instance is created - so re-run once real settings (if any) arrive.
    onPluginDataChanged: {
        refreshData()
    }

    // Results from one mode mean nothing in the other (e.g. a standard-mode "can compare" left
    // over from the default-settings check at startup would show "-1 inputs" in flake mode).
    onModeChanged: resetCheckState()

    // Settings arrive together (see onPluginDataChanged): callLater folds them into one restart.
    onWatchEnabledChanged: {
        Qt.callLater(root.restartFlakeWatch)
        Qt.callLater(root.restartSystemWatch)
    }
    onFlakeWatchCommandChanged: Qt.callLater(root.restartFlakeWatch)
    onSystemWatchCommandChanged: Qt.callLater(root.restartSystemWatch) // pluginDir resolved late

    onSystemCheckEnabledChanged: {
        if (!root.systemCheckEnabled) {
            root.systemResult = null
            root.systemError = ""
        }
    }

    // ---- Bar pills ---------------------------------------------------------------------
    // Snowflake = flake inputs vs upstream (with the outdated count); the rebuild icon after
    // it appears only when the running system is behind the flake (or couldn't be checked).

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: "ac_unit"
                size: root.iconSize
                color: root.statusColor()
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.outdatedInputCount.toString()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showOutdatedCount
            }

            DIcon {
                name: "arrow_forward"
                size: root.iconSize - 6
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showSystemBadge
            }

            DIcon {
                name: root.systemState === "error" ? "sync_problem" : "restart_alt"
                size: root.iconSize
                color: root.stateColor(root.systemState, root.systemChecking)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showSystemBadge
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DIcon {
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

            DIcon {
                name: root.systemState === "error" ? "sync_problem" : "restart_alt"
                size: root.iconSize
                color: root.stateColor(root.systemState, root.systemChecking)
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.showSystemBadge
            }
        }
    }

    // ---- Popout ------------------------------------------------------------------------
    // One column sized by its content (PluginPopout follows its implicitHeight): a hero card
    // with the verdict and the pipeline, then - flake mode - the outdated inputs and the
    // package changes. States with nothing to list give a short popout.

    popoutWidth: 500

    component SectionLabel: Item {
        id: sectionLabel
        property string title: ""
        property string trailing: ""

        width: parent ? parent.width : 0
        height: 18

        StyledText {
            id: sectionTitleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: sectionLabel.title
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Bold
            font.letterSpacing: 1
            color: Theme.surfaceVariantText
        }

        StyledText {
            anchors.left: sectionTitleText.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: sectionLabel.trailing
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideLeft
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Nix Update Monitor"
            showCloseButton: true

            headerActions: Component {
                DRefreshButton {
                    busy: root.isCheckingUpdates || root.systemChecking
                    tooltipText: "Check now"
                    onClicked: {
                        root.forceDiff = true
                        root.refreshData()
                    }
                }
            }

            Column {
                id: body
                x: Theme.spacingXS
                width: parent.width - Theme.spacingXS * 2
                spacing: Theme.spacingM
                bottomPadding: Theme.spacingXS

                readonly property bool pipeline: root.isFlake && root.checkUpdates

                // ---- Hero: verdict, then the pipeline (flake) or the revisions (standard) ----
                DCard {
                    id: hero
                    width: parent.width
                    height: heroColumn.implicitHeight + pad * 2
                    color: Theme.withAlpha(root.resultColor(), 0.12)
                    border.color: Theme.withAlpha(root.resultColor(), 0.35)

                    Column {
                        id: heroColumn
                        width: parent.width
                        spacing: Theme.spacingM

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            Rectangle {
                                width: 36
                                height: 36
                                radius: 18
                                color: Theme.withAlpha(root.resultColor(), 0.16)
                                anchors.verticalCenter: parent.verticalCenter

                                // Static on purpose: the header's refresh button already spins
                                // while a check runs.
                                DIcon {
                                    anchors.centerIn: parent
                                    name: root.statusIcon()
                                    size: Theme.iconSize - 2
                                    color: root.resultColor()
                                    filled: true
                                }
                            }

                            Column {
                                width: parent.width - 36 - parent.spacing
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0

                                StyledText {
                                    width: parent.width
                                    text: root.statusTitle()
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: {
                                        if (!root.checkUpdates) return root.statusSubtitle()
                                        var where = root.isFlake ? root.shortenHome(root.flakeDirectory) : root.nixpkgsChannel
                                        return root.lastUpdate ? (where + "  ·  checked " + root.lastUpdate) : where
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideMiddle
                                }
                            }
                        }

                        // ---- Standard mode: revisions ----
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: Theme.spacingXL
                            visible: !root.isFlake && root.checkUpdates

                            Repeater {
                                model: [
                                    { label: "Local", value: root.localRevision, icon: "computer" },
                                    { label: "Remote · " + root.nixpkgsChannel, value: root.remoteRevision, icon: "cloud" }
                                ]

                                Row {
                                    required property var modelData
                                    spacing: Theme.spacingS

                                    DIcon {
                                        name: modelData.icon
                                        size: Theme.iconSize - 4
                                        color: Theme.surfaceVariantText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        StyledText {
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            text: modelData.value
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.family: "monospace"
                                            color: Theme.surfaceText
                                        }
                                    }
                                }
                            }
                        }

                        // ---- Pipeline stepper: upstream → flake.lock → system ----
                        Item {
                            id: stepper
                            width: parent.width
                            height: 62
                            visible: body.pipeline

                            readonly property int nodeWidth: 84
                            readonly property int circle: 40
                            readonly property int linkWidth: (width - nodeWidth * 3) / 2

                            Repeater {
                                model: [
                                    { icon: "cloud", label: "Upstream" },
                                    { icon: "lock", label: "flake.lock" },
                                    { icon: "computer", label: "System" }
                                ]

                                Column {
                                    required property var modelData
                                    required property int index
                                    x: index * (stepper.nodeWidth + stepper.linkWidth)
                                    width: stepper.nodeWidth
                                    spacing: Theme.spacingXS

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: stepper.circle
                                        height: stepper.circle
                                        radius: stepper.circle / 2
                                        color: Theme.cardSurface
                                        border.width: 1
                                        border.color: Theme.outlineMedium

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: modelData.icon
                                            size: Theme.iconSize - 4
                                            color: Theme.surfaceText
                                        }
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.label
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            Repeater {
                                model: ["inputs", "system"]

                                Item {
                                    id: link
                                    required property string modelData
                                    required property int index
                                    readonly property string linkState: modelData === "system" ? root.systemState : root.inputsState
                                    readonly property bool checking: modelData === "system" ? root.systemChecking : root.inputsChecking
                                    readonly property color tint: root.stateColor(linkState, checking)

                                    x: stepper.nodeWidth + index * (stepper.nodeWidth + stepper.linkWidth)
                                    width: stepper.linkWidth
                                    height: stepper.height

                                    Rectangle {
                                        x: Theme.spacingXS
                                        y: stepper.circle / 2 - height / 2
                                        width: parent.width - Theme.spacingXS * 2
                                        height: 3
                                        radius: 1.5
                                        color: link.tint
                                        opacity: link.linkState === "off" ? 0.35 : 1
                                    }

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: stepper.circle / 2 - height / 2
                                        width: 12
                                        height: 12
                                        radius: 6
                                        color: link.tint
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        y: stepper.circle / 2 + 12
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: root.linkLabel(link.modelData)
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: link.linkState === "off" || link.linkState === "unknown" ? Theme.surfaceVariantText : link.tint
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        // ---- Running system: generation and when it was switched to ----
                        StyledText {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            visible: body.pipeline && text !== ""
                            text: root.systemGenerationText()
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }
                }

                // ---- Outdated inputs ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: body.pipeline && root.inputsState === "behind"

                    SectionLabel {
                        title: "INPUTS"
                        trailing: root.outdatedInputCount + " newer upstream"
                    }

                    Column {
                        id: inputList
                        width: parent.width
                        spacing: 2

                        readonly property var rows: root.inputRows()
                        readonly property int hidden: rows.length - root.inputRowLimit

                        Repeater {
                            model: root.showAllInputs ? inputList.rows : inputList.rows.slice(0, root.inputRowLimit)

                            DListRow {
                                id: inputRow
                                required property var modelData
                                required property int index

                                width: inputList.width
                                height: 38
                                firstInGroup: index === 0
                                lastInGroup: inputList.hidden <= 0 && index === inputList.rows.length - 1

                                StyledText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width * 0.42)
                                    text: inputRow.modelData.name
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !!inputRow.modelData.oldRev
                                        text: visible
                                            ? inputRow.modelData.oldRev.slice(0, 7) + " → " + (inputRow.modelData.newRev || "?").slice(0, 7)
                                            : ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: "monospace"
                                        color: Theme.surfaceVariantText
                                    }

                                    DBadge {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: text !== ""
                                        color: Theme.chipSurface
                                        textColor: Theme.surfaceText
                                        text: root.formatAge(inputRow.modelData.oldDate, inputRow.modelData.newDate)
                                        tooltipText: inputRow.modelData.newDate
                                            ? "Upstream: " + Qt.formatDate(new Date(inputRow.modelData.newDate * 1000), "d MMM yyyy")
                                            : null
                                    }
                                }
                            }
                        }

                        DListRow {
                            width: inputList.width
                            height: 34
                            visible: inputList.hidden > 0
                            firstInGroup: false

                            StyledText {
                                anchors.centerIn: parent
                                text: root.showAllInputs ? "Show less" : "Show " + inputList.hidden + " more"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.primary
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showAllInputs = !root.showAllInputs
                            }
                        }
                    }
                }

                // ---- Running system → updated flake ----
                Loader {
                    width: parent.width
                    active: body.pipeline
                    visible: active
                    sourceComponent: diffPanel
                }
            }
        }
    }

    // The package diff: running system → flake with updated inputs. One state card while it's
    // computing, failed, empty or off; otherwise filter chips + searchable package list.
    Component {
        id: diffPanel

        Column {
            id: dp
            spacing: Theme.spacingS

            readonly property bool showList: root.activeDiff !== null && root.activeTotal > 0
            readonly property var info: root.diffState

            SectionLabel {
                title: "PACKAGE CHANGES"
                trailing: root.baselineText()
            }

            // ---- Computing / failed / nothing to do / off ----
            DCard {
                width: parent.width
                height: 76
                visible: !dp.showList

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    spacing: Theme.spacingM

                    Item {
                        width: 40
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter

                        DLoadingIndicator {
                            anchors.centerIn: parent
                            size: 40
                            visible: dp.info.kind === "computing"
                        }

                        DIcon {
                            anchors.centerIn: parent
                            visible: dp.info.kind !== "computing"
                            name: dp.info.icon
                            size: Theme.iconSizeLarge
                            color: dp.info.color
                        }
                    }

                    Column {
                        width: parent.width - 40 - parent.spacing * 2 - (diffAction.visible ? diffAction.width + parent.spacing : 0)
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            width: parent.width
                            text: dp.info.title
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            text: dp.info.text
                            font.pixelSize: Theme.fontSizeSmall
                            color: dp.info.isError ? Theme.error : Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                    }

                    DButton {
                        id: diffAction
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dp.info.kind === "failed" || dp.info.kind === "off"
                        text: dp.info.kind === "failed" ? "Retry" : "Compute"
                        iconName: dp.info.kind === "failed" ? "refresh" : "difference"
                        onClicked: root.computeDiff(true)
                    }
                }
            }

            // ---- Filter by kind of change ----
            DFilterChips {
                id: chips
                width: parent.width
                visible: dp.showList
                model: root.filterChips
                showCheck: false // keep the status icon on the selected chip
                onSelectionChanged: index => root.statusFilter = root.filterChips[index].value

                // The chips assign currentIndex themselves on click; this keeps it following
                // statusFilter when the diff (and so the set of chips) changes.
                Binding {
                    target: chips
                    property: "currentIndex"
                    value: root.filterIndex
                }
            }

            // ---- Search ----
            DSearchField {
                width: parent.width
                visible: dp.showList
                placeholderText: "Search " + root.activeTotal + " packages"
                text: root.packageSearch
                onTextChanged: root.packageSearch = text
            }

            // ---- Package list ----
            StyledRect {
                width: parent.width
                height: (packageList.count === 0 ? 56 : Math.min(packageList.count * root.packageRowHeight, root.packageListMaxHeight))
                    + Theme.spacingXS * 2
                visible: dp.showList
                radius: Theme.cornerRadius
                color: Theme.cardSurface
                clip: true

                DListView {
                    id: packageList
                    anchors.fill: parent
                    anchors.margins: Theme.spacingXS
                    clip: true
                    model: root.packageRows
                    add: null
                    remove: null
                    displaced: null
                    move: null

                    delegate: Item {
                        id: row
                        required property var modelData

                        width: packageList.width
                        height: root.packageRowHeight

                        Rectangle {
                            anchors.fill: parent
                            radius: Theme.cornerRadius - 4
                            color: rowArea.containsMouse ? Theme.surfaceTextHover : "transparent"
                        }

                        DIcon {
                            id: rowIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.packageStatusIcon(row.modelData.status)
                            size: Theme.iconSizeSmall
                            color: root.packageStatusColor(row.modelData.status)
                        }

                        StyledText {
                            id: rowName
                            anchors.left: rowIcon.right
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, parent.width * 0.45)
                            text: row.modelData.name
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            anchors.left: rowName.right
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight
                            text: root.describeChanges(row.modelData.changes)
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: "monospace"
                            color: Theme.surfaceVariantText
                            elide: Text.ElideLeft
                        }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
                        }
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: packageList.count === 0
                    text: "No matching packages"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            // ---- Footer ----
            Item {
                width: parent.width
                height: 20
                visible: dp.showList || dp.info.kind === "same"

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.activeDiff
                        ? (root.formatSize(root.activeDiff.sizeNew - root.activeDiff.sizeOld, true)
                            + "  ·  " + root.activeDiff.paths.old + " → " + root.activeDiff.paths.new + " paths")
                        : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    DSpinner {
                        size: 14
                        visible: root.isComputingDiff
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: root.isComputingDiff ? "updating" : (root.diffOutdated ? "out of date" : "diffed " + root.lastDiffTime)
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.diffOutdated && !root.isComputingDiff ? Theme.warning : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }

    // ---- Processes ---------------------------------------------------------------------

    Timer {
        id: updateCheckTimer
        interval: root.updateCheckInterval * 1000
        running: root.checkUpdates
        repeat: true
        onTriggered: root.checkForUpdates()
    }

    // Cheap poll of /run/current-system so a switch is picked up within seconds instead of at
    // the next scheduled check. Only a fallback: it stops while the watcher below is in place.
    Timer {
        interval: 15000
        running: root.isFlake && root.checkUpdates && !root.systemWatchReady
        repeat: true
        triggeredOnStart: true
        onTriggered: root.readRunningSystem()
    }

    // Watches /run/current-system being replaced (a switch). Started/restarted by
    // restartSystemWatch(); if it exits by itself it is not respawned - the poll above takes
    // over until the watch settings change.
    Process {
        id: systemWatchProcess
        command: root.systemWatchCommand
        running: false

        stdout: SplitParser {
            onRead: function(line) { root.readRunningSystem() }
        }
        stderr: SplitParser {
            onRead: function(line) {
                if (line.indexOf("Watches established") < 0) return
                root.systemWatchReady = true
                root.readRunningSystem() // catch a switch that happened while starting up
            }
        }
        onExited: function(exitCode, exitStatus) {
            var wasReady = root.systemWatchReady
            root.systemWatchReady = false
            if (root.systemWatchRestart) {
                root.systemWatchRestart = false
                if (root.watchEnabled) systemWatchProcess.running = true
            } else if (root.watchEnabled && !wasReady) {
                console.warn("Nix Update Monitor: system watcher failed (exit code " + exitCode + "), polling instead")
            }
        }
    }

    // Watches the flake's working tree. Started/restarted by restartFlakeWatch().
    Process {
        id: flakeWatchProcess
        command: root.flakeWatchCommand
        running: false

        stdout: SplitParser {
            onRead: function(line) { root.onFlakeFileChanged(line) }
        }
        stderr: SplitParser {
            onRead: function(line) {
                if (line.indexOf("Watches established") >= 0) root.flakeWatchReady = true
            }
        }
        onExited: function(exitCode, exitStatus) {
            var wasReady = root.flakeWatchReady
            root.flakeWatchReady = false
            if (root.flakeWatchRestart) {
                root.flakeWatchRestart = false
                if (root.watchEnabled) flakeWatchProcess.running = true
            } else if (root.watchEnabled && !wasReady) {
                console.warn("Nix Update Monitor: could not watch " + root.flakeDirectory
                    + " (exit code " + exitCode + "), relying on scheduled checks")
            }
        }
    }

    // An editor save or a `nix flake update` is a burst of events (temp file, rename, several
    // files...): wait for it to settle, then run each affected check once.
    Timer {
        id: flakeChangeTimer
        interval: 3000
        onTriggered: root.applyFlakeChanges()
    }

    Process {
        id: currentSystemProcess
        command: ["readlink", "-f", "/run/current-system"]
        running: false

        stdout: SplitParser {
            onRead: function(line) {
                var path = line.trim()
                if (!path) return
                var previous = root.runningSystemPath
                if (previous === path) return
                root.runningSystemPath = path
                if (previous) root.checkSystemNow() // switched: re-check the rebuild status
                root.maybeAutoDiff()                // first value, or the diff's baseline moved
            }
        }

        onExited: function(exitCode, exitStatus) {
            // The link was replaced again while this was reading it.
            if (root.runningSystemReadPending) root.readRunningSystem()
        }
    }

    Process {
        id: localRevisionProcess
        command: root.localRevisionCommand
        running: false

        stdout: SplitParser {
            onRead: function(line) {
                var revision = line.trim()
                root.localRevision = (revision && revision !== "N/A") ? revision : "N/A"
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
                root.remoteRevision = (revision && revision !== "N/A") ? revision : "N/A"
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
            if (!root.isFlake) { // mode switched while this was running - result is stale
                flakeUpdateCheckProcess.output = ""
                root.onCheckProcessFinished()
                return
            }
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
                root.inputDetails = result.details || []
                root.lockHash = result.lockHash || ""
            } else {
                root.outdatedInputCount = -1
                root.outdatedInputs = []
                root.inputDetails = []
                root.lockHash = ""
            }
            root.inputsChecked = true

            if (root.outdatedInputCount >= 0) {
                root.canCompareVersions = true
                root.isUpToDate = root.outdatedInputCount === 0
            } else {
                root.canCompareVersions = false
                root.isUpToDate = false
            }

            root.onCheckProcessFinished()
            root.maybeAutoDiff()
        }
    }

    Process {
        id: systemSyncProcess
        command: root.systemCheckCommand
        running: false
        property string output: ""

        stdout: SplitParser {
            onRead: function(line) {
                systemSyncProcess.output += line
            }
        }

        onExited: function(exitCode, exitStatus) {
            var raw = systemSyncProcess.output.trim()
            systemSyncProcess.output = ""

            if (root.systemCheckEnabled) {
                var result = null
                try {
                    result = JSON.parse(raw)
                } catch (e) {
                    result = { status: "error", message: raw ? raw.split("\n")[0] : ("system check failed (exit code " + exitCode + ")") }
                }
                if (result.status === "synced" || result.status === "behind") {
                    root.systemResult = result
                    root.systemError = ""
                } else {
                    root.systemResult = null
                    root.systemError = result.message || "Unknown error checking the running system"
                }
                root.lastSystemCheck = Qt.formatTime(new Date(), "HH:mm")
            }

            if (root.systemCheckPending) {
                root.checkSystemNow()
            } else if (root.autoDiffDeferred) {
                root.autoDiffDeferred = false
                root.maybeAutoDiff()
            }
        }
    }

    Process {
        id: diffProcess
        command: root.diffCommand
        running: false
        property string output: ""

        stdout: SplitParser {
            onRead: function(line) {
                diffProcess.output += line
            }
        }

        onExited: function(exitCode, exitStatus) {
            var raw = diffProcess.output.trim()
            diffProcess.output = ""
            var finishedKey = root.runningDiffKey
            root.runningDiffKey = ""

            var result = null
            try {
                result = JSON.parse(raw)
            } catch (e) {
                result = { status: "error", message: raw ? raw.split("\n")[0] : ("diff command failed (exit code " + exitCode + ")") }
            }

            root.diffKey = finishedKey
            root.lastDiffTime = Qt.formatTime(new Date(), "HH:mm")
            if (result.status === "ok" || result.status === "same") {
                root.diffResult = result
                root.diffError = ""
            } else {
                root.diffResult = null
                root.diffError = result.message || "Unknown error computing the package diff"
            }

            // A newer set of input revisions arrived while this one was evaluating.
            var queued = root.queuedDiffKey
            root.queuedDiffKey = ""
            // (Or the same key, forced: the flake's files changed while this was evaluating.)
            if (queued) {
                root.startDiff(queued)
            } else {
                root.isComputingDiff = false
            }
        }
    }

    // ---- Logic -------------------------------------------------------------------------

    property bool runningSystemReadPending: false

    function readRunningSystem() {
        if (currentSystemProcess.running) {
            root.runningSystemReadPending = true
            return
        }
        root.runningSystemReadPending = false
        currentSystemProcess.running = true
    }

    // (Re)starts the flake-tree watcher so it follows flakeDirectory and the watch settings.
    // A running one has to exit first; its onExited then starts the new one.
    function restartFlakeWatch() {
        flakeChangeTimer.stop()
        root.pendingInputsChange = false
        root.pendingTreeChange = false
        if (flakeWatchProcess.running) {
            root.flakeWatchRestart = root.watchEnabled
            flakeWatchProcess.running = false
        } else if (root.watchEnabled) {
            flakeWatchProcess.running = true
        }
    }

    function restartSystemWatch() {
        if (systemWatchProcess.running) {
            root.systemWatchRestart = root.watchEnabled
            systemWatchProcess.running = false
        } else if (root.watchEnabled) {
            systemWatchProcess.running = true
        }
    }

    function onFlakeFileChanged(path) {
        var name = path.substring(path.lastIndexOf("/") + 1)
        if (!name) return
        if (name === "flake.lock" || name === "flake.nix") root.pendingInputsChange = true
        // flake.lock alone doesn't change what "updated inputs + rebuild" evaluates to.
        if (name !== "flake.lock") root.pendingTreeChange = true
        flakeChangeTimer.restart()
    }

    function applyFlakeChanges() {
        var inputs = root.pendingInputsChange
        var tree = root.pendingTreeChange
        root.pendingInputsChange = false
        root.pendingTreeChange = false
        if (!root.watchEnabled) return
        // Local edits don't show up in the diff key, so the diff has to be forced.
        if (tree) root.forceDiff = true
        if (inputs) {
            // Locked revisions (or the inputs themselves) changed: full round, which also
            // re-checks the system and ends in maybeAutoDiff().
            root.checkForUpdates()
        } else if (tree) {
            // Config edit only: nothing upstream to ask about, so no network round.
            root.checkSystemNow()
            root.maybeAutoDiff()
        }
    }

    function refreshData() {
        if (root.checkUpdates) {
            root.checkForUpdates()
        } else {
            root.lastUpdate = Qt.formatTime(new Date(), "HH:mm")
        }
    }

    function checkForUpdates() {
        // The system check has its own queue, independent of the input-check round below.
        if (root.isFlake) root.checkSystemNow()

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
        if (root.isFlake) {
            root.pendingCheckProcesses = 1
            flakeUpdateCheckProcess.output = ""
            flakeUpdateCheckProcess.running = true
        } else {
            root.pendingCheckProcesses = 2
            localRevisionProcess.running = true
            remoteRevisionProcess.running = true
        }
    }

    // Evaluates the flake and compares it with /run/current-system. A request while one is
    // running is queued once (settings can change right after startup, see checkForUpdates).
    function checkSystemNow() {
        if (!root.systemCheckEnabled) return
        if (systemSyncProcess.running) {
            root.systemCheckPending = true
            return
        }
        root.systemCheckPending = false
        systemSyncProcess.output = ""
        systemSyncProcess.running = true
    }

    // Called by each update-check Process's onExited (standard mode runs two in parallel, so
    // this only closes out the round - and retries if one was queued - once all of them are done.
    function onCheckProcessFinished() {
        root.pendingCheckProcesses -= 1
        if (root.pendingCheckProcesses > 0) return
        root.isCheckingUpdates = false
        root.lastUpdate = Qt.formatTime(new Date(), "HH:mm")
        if (root.checkUpdatesPending) {
            root.checkForUpdates()
        }
    }

    function updateUpToDateStatus() {
        if (root.isFlake) return // standard-mode process finishing after a switch to flake mode
        if (root.localRevision !== "..." && root.remoteRevision !== "..." &&
            root.localRevision !== "N/A" && root.remoteRevision !== "N/A") {
            root.canCompareVersions = true
            root.isUpToDate = (root.localRevision === root.remoteRevision)
        } else {
            root.canCompareVersions = false
            root.isUpToDate = false
        }
    }

    // Identifies what the diff compares: the running system against this flake/output with this
    // updated lock. Empty while either side is unknown.
    function currentDiffKey() {
        if (!root.isFlake || !root.inputsChecked || root.outdatedInputCount < 0) return ""
        var lock = root.lockHash || root.inputDetails.map(function(d) { return d.name + "@" + d.newRev }).join(",")
        return [root.flakeDirectory, root.flakeOutputAttr, lock, root.runningSystemPath].join("|")
    }

    // The baseline is /run/current-system for NixOS outputs; wait for its first poll so the
    // diff isn't computed twice at startup.
    readonly property bool needsRunningSystem: root.flakeOutputAttr === "" || root.flakeOutputAttr.indexOf("nixosConfigurations.") === 0

    function maybeAutoDiff() {
        if (root.checkUpdatesPending) return // a re-check with fresh settings is coming
        var key = root.currentDiffKey()
        if (!key) {
            // Input check failed (or not done yet): keep whatever is shown.
            if (root.inputsState === "error" && !root.isComputingDiff) {
                root.diffResult = null
                root.diffError = ""
                root.diffKey = ""
            }
            return
        }
        if (root.needsRunningSystem && !root.runningSystemPath) return
        if (!root.autoDiff) return
        var force = root.forceDiff
        root.forceDiff = false
        if (!force) {
            // Already showing (or computing) this exact comparison - don't re-evaluate.
            // Errors are retried on the next check.
            if (key === root.runningDiffKey || key === root.queuedDiffKey) return
            if (key === root.diffKey && !root.diffError) return
        }
        // Don't stack two full evaluations on top of the running system check.
        if (systemSyncProcess.running) {
            root.autoDiffDeferred = true
            if (force) root.forceDiff = true
            return
        }
        root.computeDiff(force)
    }

    function computeDiff(force) {
        var key = root.currentDiffKey()
        if (!key) return
        if (diffProcess.running) {
            if (key !== root.runningDiffKey || force) root.queuedDiffKey = key
            return
        }
        root.startDiff(key)
    }

    function startDiff(key) {
        root.runningDiffKey = key
        root.isComputingDiff = true
        diffProcess.output = ""
        diffProcess.running = true
    }

    function resetCheckState() {
        root.canCompareVersions = false
        root.isUpToDate = true
        root.inputsChecked = false
        root.outdatedInputCount = -1
        root.outdatedInputs = []
        root.inputDetails = []
        root.lockHash = ""
        root.localRevision = "..."
        root.remoteRevision = "..."
        root.systemResult = null
        root.systemError = ""
        if (!root.isComputingDiff) {
            root.diffResult = null
            root.diffError = ""
            root.diffKey = ""
        }
    }

    function inputRows() {
        if (root.inputDetails.length > 0) return root.inputDetails
        return root.outdatedInputs.map(function(n) { return { name: n } })
    }

    // green = up to date, blue = checking, orange = update available, red = error/unknown.
    // Theme.primary (neutral) only applies when update checking is disabled entirely.
    // In flake mode this is the flake-inputs link only (the bar's snowflake).
    function statusColor() {
        if (!root.checkUpdates) return Theme.primary
        if (root.isCheckingUpdates) return Theme.info
        if (!root.canCompareVersions) return Theme.error
        return root.isUpToDate ? Theme.success : Theme.warning
    }

    // Color of one pipeline link. "checking" only shows (blue) while there's no result yet.
    function stateColor(state, checking) {
        switch (state) {
        case "synced": return Theme.success
        case "behind": return Theme.warning
        case "error": return Theme.error
        case "unknown": return checking ? Theme.info : Theme.surfaceVariantText
        }
        return Theme.surfaceVariantText
    }

    // The popout's static status icon. Flake mode: the worst of both links. Keeps the last
    // result's color during a re-check (the bar icon still turns blue to show a check is running).
    function resultColor() {
        if (root.isFlake && root.checkUpdates) return root.stateColor(root.overallState, true)
        if (root.checkUpdates && root.isCheckingUpdates && !root.canCompareVersions) return Theme.info
        return root.isCheckingUpdates && root.checkUpdates
            ? (root.isUpToDate ? Theme.success : Theme.warning)
            : root.statusColor()
    }

    function statusIcon() {
        if (!root.checkUpdates) return "pause_circle"
        if (root.isFlake) {
            switch (root.overallState) {
            case "error": return "error"
            case "behind": return "update"
            case "synced": return "check_circle"
            }
            return "sync"
        }
        if (root.isCheckingUpdates && !root.canCompareVersions) return "sync" // first check, no result yet
        if (!root.canCompareVersions) return "error"
        return root.isUpToDate ? "check_circle" : "update"
    }

    function statusTitle() {
        if (!root.checkUpdates) return "Update checking is off"
        if (root.isFlake) {
            var i = root.inputsState
            var s = root.systemState
            var bits = []
            if (i === "behind") bits.push(root.outdatedInputCount + " input" + (root.outdatedInputCount === 1 ? "" : "s") + " can be updated")
            if (s === "behind") bits.push("rebuild pending")
            if (i === "error") bits.push("could not check inputs")
            if (s === "error") bits.push("could not check system")
            if (bits.length > 0) {
                var t = bits.join("  ·  ")
                return t.charAt(0).toUpperCase() + t.slice(1)
            }
            if (i === "synced" && (s === "synced" || s === "off")) return "Everything is up to date"
            return "Checking for updates..."
        }
        if (root.isCheckingUpdates && root.lastUpdate === "") return "Checking for updates..."
        if (!root.canCompareVersions) return "Could not fetch version info"
        return root.isUpToDate ? "Nixpkgs is up to date" : "Nixpkgs update available"
    }

    function statusSubtitle() {
        if (!root.checkUpdates) return "Enable it in the plugin settings."
        if (!root.canCompareVersions) return ""
        return root.isUpToDate ? ("Tracking " + root.nixpkgsChannel) : (root.localRevision + " → " + root.remoteRevision)
    }

    // Short label under each stepper link.
    function linkLabel(section) {
        var state = section === "system" ? root.systemState : root.inputsState
        switch (state) {
        case "off": return "not checked"
        case "unknown": return "checking…"
        case "error": return "error"
        case "synced": return section === "system" ? "applied" : "up to date"
        }
        return section === "system" ? "not applied" : (root.outdatedInputCount + " newer")
    }

    function systemGenerationText() {
        var r = root.systemResult
        if (!r) return ""
        var parts = []
        if (r.generation !== null && r.generation !== undefined) parts.push("Generation " + r.generation)
        if (r.switchedAt) parts.push("switched " + root.formatAgo(r.switchedAt))
        return parts.join("  ·  ")
    }

    // Right side of the diff panel's label: what the diff is measured against.
    function baselineText() {
        var d = root.diffResult
        if (!d || !d.baseline) return ""
        if (d.baseline === "lock") return "vs current flake.lock"
        var r = root.systemResult
        return r && r.generation !== null && r.generation !== undefined
            ? "vs running system · gen " + r.generation : "vs running system"
    }

    function packageStatusIcon(status) {
        switch (status) {
        case "upgraded": return "arrow_upward"
        case "downgraded": return "arrow_downward"
        case "added": return "add"
        case "removed": return "remove"
        }
        return "circle"
    }

    function packageStatusColor(status) {
        switch (status) {
        case "upgraded": return Theme.success
        case "downgraded": return Theme.warning
        case "added": return Theme.info
        case "removed": return Theme.error
        }
        return Theme.surfaceVariantText
    }

    function describeChanges(changes) {
        return changes.map(function(c) {
            if (c.old && c.new) return c.old + " → " + c.new
            return c.new ? ("+ " + c.new) : ("− " + c.old)
        }).join(",  ")
    }

    function formatSize(bytes, signed) {
        var a = Math.abs(bytes)
        var sign = signed ? (bytes < 0 ? "−" : "+") : ""
        if (a >= 1073741824) return sign + (a / 1073741824).toFixed(2) + " GiB"
        if (a >= 1048576) return sign + (a / 1048576).toFixed(1) + " MiB"
        if (a >= 1024) return sign + (a / 1024).toFixed(0) + " KiB"
        return sign + a + " B"
    }

    // "+4 days" style gap between the locked and the upstream commit dates.
    function formatAge(oldDate, newDate) {
        if (!oldDate || !newDate) return ""
        var s = newDate - oldDate
        if (s < 3600) return "+" + Math.max(1, Math.round(s / 60)) + " min"
        if (s < 86400) return "+" + Math.round(s / 3600) + " h"
        var d = Math.round(s / 86400)
        return "+" + d + " day" + (d === 1 ? "" : "s")
    }

    // "3 h ago" style age of a unix timestamp.
    function formatAgo(seconds) {
        var s = Math.max(0, Date.now() / 1000 - seconds)
        if (s < 60) return "just now"
        if (s < 3600) return Math.round(s / 60) + " min ago"
        if (s < 86400) return Math.round(s / 3600) + " h ago"
        var d = Math.round(s / 86400)
        return d + " day" + (d === 1 ? "" : "s") + " ago"
    }

    function shortenHome(path) {
        var home = Quickshell.env("HOME")
        return home && path.indexOf(home) === 0 ? "~" + path.slice(home.length) : path
    }
}
