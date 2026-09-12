import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Suspend/Reboot/Shutdown, reachable without unlocking (same convention as
// login/lock screens elsewhere). Each button arms on first click and must be
// clicked again within a few seconds to actually fire, so a stray tap on the
// lock screen can't accidentally suspend or reboot the machine.
Item {
  id: root

  // Gated by the lock's own inputEnabled: disabled while the screen is
  // asleep/blanked (before a wake gesture) and during Settings previews, so
  // a stray click there can never suspend/reboot/shut down for real.
  property bool interactive: true

  readonly property int buttonSize: 40

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight
  width: implicitWidth
  height: implicitHeight

  Row {
    id: row
    spacing: Style.space(10)

    Repeater {
      model: [
        { glyph: "󰒲", label: "Suspend", command: ["systemctl", "suspend"] },
        { glyph: "󰜉", label: "Reboot", command: ["omarchy-system-reboot"] },
        { glyph: "󰐥", label: "Shutdown", command: ["omarchy-system-shutdown"] }
      ]

      delegate: BorderSurface {
        id: btn
        property bool armed: false
        width: root.buttonSize
        height: root.buttonSize
        radius: Style.cornerRadius
        opacity: root.interactive ? 1.0 : 0.45
        color: armed
          ? Util.alpha(Color.lock.borderError, 0.3)
          : (mouse.containsMouse ? Util.alpha(Color.lock.border, 0.2) : Util.alpha(Color.lock.background, 0.5))
        borderSpec: Border.surfaceSpec(
          "lock",
          armed ? "border-error" : "border",
          armed ? Color.lock.borderError : Color.lock.border,
          armed ? 2 : 1,
          "border-alpha"
        )

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: modelData.glyph
          color: btn.armed ? Color.lock.textError : Color.lock.placeholder
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.body * 1.3)
        }

        Timer {
          id: disarmTimer
          interval: 3000
          onTriggered: btn.armed = false
        }

        MouseArea {
          id: mouse
          anchors.fill: parent
          enabled: root.interactive
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (btn.armed) {
              disarmTimer.stop()
              btn.armed = false
              Quickshell.execDetached(modelData.command)
            } else {
              btn.armed = true
              disarmTimer.restart()
            }
          }
        }

        // Minimal tooltip-ish hint shown only while armed, so the confirm
        // step is legible without adding a native QQC2 ToolTip dependency.
        Text {
          visible: btn.armed
          anchors.top: parent.bottom
          anchors.topMargin: Style.space(4)
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: "Confirm " + modelData.label
          color: Color.lock.textError
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
