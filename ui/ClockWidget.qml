import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property date currentTime: new Date()
  property string dateFormat: ""
  property string timeFormat: ""
  property string localDateFormat: ""
  property string localTimeFormat: ""

  readonly property string activeDateFormat: dateFormat ? dateFormat : localDateFormat
  readonly property string activeTimeFormat: timeFormat ? timeFormat : localTimeFormat

  readonly property string defaultDateFormat: "dddd, MMMM d"
  readonly property string defaultTimeFormat: "h:mm AP"

  readonly property string effectiveDateFormat: (activeDateFormat && activeDateFormat.trim() !== "") ? activeDateFormat : defaultDateFormat
  readonly property string effectiveTimeFormat: (activeTimeFormat && activeTimeFormat.trim() !== "") ? activeTimeFormat : defaultTimeFormat

  readonly property int timeFontSize: Math.round(Style.font.heading * 3.8)
  readonly property int dateFontSize: Math.round(Style.font.body * 1.15)
  readonly property string timeString: Qt.formatTime(currentTime, root.effectiveTimeFormat)
  readonly property string dateString: {
    var raw = Qt.formatDate(currentTime, root.effectiveDateFormat)
    return raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : ""
  }

  implicitWidth: clockCol.implicitWidth
  implicitHeight: clockCol.implicitHeight
  width: implicitWidth
  height: implicitHeight

  FileView {
    id: fallbackSettingsFile
    path: Quickshell.env("HOME") + "/.config/omalock/settings.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && d.dateFormat) root.localDateFormat = String(d.dateFormat)
        if (d && d.timeFormat) root.localTimeFormat = String(d.timeFormat)
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  Timer {
    id: clockTimer
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.currentTime = new Date()
  }

  Column {
    id: clockCol
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(4)

    Text {
      id: timeText
      text: root.timeString
      color: Color.lock.text
      font.family: Style.font.family
      font.pixelSize: root.timeFontSize
      font.weight: Font.ExtraLight
      horizontalAlignment: Text.AlignHCenter
      anchors.horizontalCenter: parent.horizontalCenter
    }

    Text {
      id: dateText
      text: root.dateString
      color: Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: root.dateFontSize
      horizontalAlignment: Text.AlignHCenter
      anchors.horizontalCenter: parent.horizontalCenter
    }
  }
}
