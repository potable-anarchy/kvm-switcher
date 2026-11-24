// KVM Switch — system tray widget for KDE Plasma 6.
// The icon is bright when this machine owns the monitor's keyboard/mouse and dimmed
// when the other computer does. Click: status popup. Middle-click: switch.
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string bin: '"$HOME/.local/bin/kvm-switch"'
    readonly property string cmdOwner: bin + " owner"
    readonly property string cmdStatus: bin + " status --kv"
    readonly property string cmdToggle: bin + " toggle"

    property bool usbHere: true
    property string pbp: "…"
    property string input: "…"
    property bool busy: false
    property string error: ""

    Plasmoid.icon: "view-split-left-right"
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    toolTipMainText: "KVM Switch"
    toolTipSubText: usbHere ? "Keyboard and mouse are here" : "Keyboard and mouse are on the other computer"

    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            root.handle(source, (data["stdout"] || "").trim(), data["exit code"])
        }
        function run(cmd) { connectSource(cmd) }
    }

    function handle(source, out, code) {
        if (source === cmdOwner) {
            if (out === "here" || out === "other") usbHere = (out === "here")
        } else if (source === cmdStatus) {
            if (code !== 0) { error = "Monitor not reachable over DDC"; return }
            error = ""
            out.split("\n").forEach(line => {
                const [k, v] = line.split("=")
                if (k === "pbp") pbp = v
                else if (k === "input") input = v
                else if (k === "usb") usbHere = (v === "here")
            })
        } else if (source === cmdToggle) {
            busy = false
            if (code !== 0) error = "Switch failed"
            settle.restart()
        }
    }

    function toggle() {
        if (busy) return
        busy = true
        exec.run(cmdToggle)
    }

    // Poll ownership (cheap, no DDC); fetch full status only while the popup is open.
    Timer {
        interval: 2000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: exec.run(root.cmdOwner)
    }
    Timer {
        id: settle   // the USB hub takes a few seconds to re-enumerate after a switch
        interval: 3000
        onTriggered: { exec.run(root.cmdOwner); if (root.expanded) exec.run(root.cmdStatus) }
    }
    onExpandedChanged: if (expanded) exec.run(cmdStatus)

    compactRepresentation: MouseArea {
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) root.toggle()
            else root.expanded = !root.expanded
        }
        Kirigami.Icon {
            anchors.fill: parent
            source: Plasmoid.icon
            active: parent.containsMouse
            opacity: root.usbHere ? 1.0 : 0.35
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 16
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading { level: 3; text: "KVM Switch" }

        Kirigami.FormLayout {
            Layout.fillWidth: true
            PlasmaComponents3.Label {
                Kirigami.FormData.label: "Keyboard & mouse:"
                text: root.usbHere ? "here" : "other computer"
            }
            PlasmaComponents3.Label { Kirigami.FormData.label: "PBP:"; text: root.pbp }
            PlasmaComponents3.Label { Kirigami.FormData.label: "Main input:"; text: root.input }
        }

        PlasmaComponents3.Label {
            visible: root.error !== ""
            text: root.error
            color: Kirigami.Theme.negativeTextColor
        }

        PlasmaComponents3.Button {
            Layout.fillWidth: true
            text: root.busy ? "Switching…" : "Switch to Other Computer"
            icon.name: "go-next"
            enabled: !root.busy
            onClicked: root.toggle()
        }

        PlasmaComponents3.Label {
            Layout.alignment: Qt.AlignHCenter
            text: "Hotkey: Ctrl+Alt+Meta+K · middle-click icon to switch"
            font: Kirigami.Theme.smallFont
            opacity: 0.6
        }
    }
}
