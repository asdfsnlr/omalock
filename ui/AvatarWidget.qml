import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property string avatarPath: ""
  property string localAvatarPath: ""
  property string shape: ""
  property string localShape: ""

  readonly property string activeAvatarPath: avatarPath ? avatarPath : localAvatarPath
  readonly property int avatarSize: Style.space(92)
  readonly property string effectiveShape: (shape || localShape || "circle")
  readonly property real shapeRadius: effectiveShape === "square" ? Style.cornerRadius : (avatarSize / 2)

  readonly property string effectivePath: {
    var p = String(activeAvatarPath || "").trim()
    if (!p) return ""
    if (p.startsWith("~")) p = Quickshell.env("HOME") + p.slice(1)
    return p
  }

  readonly property string avatarUrl: effectivePath ? Util.fileUrl(effectivePath) : ""
  readonly property bool hasAvatar: effectivePath.length > 0 && avatarImg.status === Image.Ready

  visible: hasAvatar
  implicitWidth: hasAvatar ? avatarSize : 0
  implicitHeight: hasAvatar ? avatarSize : 0
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
        if (d && d.avatarPath !== undefined) root.localAvatarPath = String(d.avatarPath)
        if (d && d.avatarShape !== undefined) root.localShape = String(d.avatarShape)
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  Item {
    id: avatarContent
    anchors.centerIn: parent
    width: root.avatarSize
    height: root.avatarSize
    visible: root.hasAvatar

    Item {
      id: maskItem
      anchors.fill: parent
      visible: false
      layer.enabled: true

      Rectangle {
        anchors.fill: parent
        radius: root.shapeRadius
        color: "black"
      }
    }

    Image {
      id: avatarImg
      anchors.fill: parent
      source: root.avatarUrl
      fillMode: Image.PreserveAspectCrop
      visible: false
      asynchronous: true
      cache: true
    }

    MultiEffect {
      anchors.fill: parent
      source: avatarImg
      maskEnabled: true
      maskSource: maskItem
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.1
    }

    Rectangle {
      anchors.fill: parent
      radius: root.shapeRadius
      color: "transparent"
      border.color: Util.alpha(Color.lock.border, 0.4)
      border.width: 1
    }
  }
}
