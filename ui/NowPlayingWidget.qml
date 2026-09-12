import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Now-playing widget for whatever MPRIS-compliant player is currently
// active (Spotify, a YouTube Music PWA/extension exposing MPRIS, VLC, mpv,
// Rhythmbox, etc.) via Omarchy's own stock media service. Hidden entirely
// when nothing is playing.
Item {
  id: root

  property var mediaService: null
  property string albumArtPosition: ""
  property string localAlbumArtPosition: ""

  readonly property string effectiveAlbumArtPosition: {
    var pos = (albumArtPosition || localAlbumArtPosition || "top").trim().toLowerCase()
    return (pos === "left" || pos === "right" || pos === "top") ? pos : "top"
  }

  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null
  readonly property bool hasPlayer: activePlayer !== null

  readonly property bool isPlaying: hasPlayer ? (activePlayer.isPlaying === true) : false
  readonly property string trackTitle: hasPlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string trackArtist: hasPlayer ? String(activePlayer.trackArtist || "") : ""
  readonly property bool hasTrack: hasPlayer && (trackTitle.length > 0 || trackArtist.length > 0)
  readonly property string trackLabel: {
    if (trackTitle.length > 0 && trackArtist.length > 0)
      return trackTitle + " — " + trackArtist
    return trackTitle || trackArtist
  }

  readonly property real trackLength: (hasPlayer && activePlayer.lengthSupported)
    ? Math.max(0, activePlayer.length)
    : 0

  property real basePosition: 0
  property double baseTimestamp: 0
  property real currentPosition: 0

  readonly property real progress: trackLength > 0
    ? Math.max(0, Math.min(1, currentPosition / trackLength))
    : 0

  // ---------------------------------------------------------------- Album Art
  readonly property int artSize: 64

  property string currentTargetUrl: ""
  property string activeArtSource: ""
  property bool hasArt: false
  property bool artImageReady: false

  FileView {
    id: fallbackSettingsFile
    path: Quickshell.env("HOME") + "/.config/omalock/settings.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && d.albumArtPosition) root.localAlbumArtPosition = String(d.albumArtPosition)
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  function getPlayerArtUrl() {
    if (!hasPlayer) return ""
    var url = ""
    if (activePlayer.trackArtUrl) {
      url = String(activePlayer.trackArtUrl)
    } else if (activePlayer.metadata && activePlayer.metadata["mpris:artUrl"]) {
      url = String(activePlayer.metadata["mpris:artUrl"])
    }
    return url ? url.trim() : ""
  }

  readonly property string rawArtUrl: getPlayerArtUrl()

  readonly property bool showAlbumArt: root.hasArt && root.artImageReady

  // Deliberately local-only: mpris:artUrl/trackArtUrl is metadata reported
  // by *any* MPRIS-capable player in the session (Spotify, a browser tab's
  // extension, etc.) and updates automatically, unauthenticated, on the
  // lock screen. Automatically fetching an attacker-chosen http(s):// URL
  // from there would be an SSRF primitive reachable pre-login by anything
  // in the session -- so only already-local image sources (a real file
  // path the player points at) are ever loaded; remote URLs are ignored.
  function syncArt() {
    var raw = getPlayerArtUrl()
    if (raw === currentTargetUrl && hasArt) return
    currentTargetUrl = raw
    root.artImageReady = false

    if (!raw || raw.length === 0) {
      hasArt = false
      activeArtSource = ""
      return
    }

    if (raw.startsWith("file://")) {
      var localPath = raw.substring(7)
      try { localPath = decodeURIComponent(localPath) } catch (e) {}
      activeArtSource = Util.fileUrl(localPath)
      hasArt = true
      return
    }

    if (raw.startsWith("/")) {
      activeArtSource = Util.fileUrl(raw)
      hasArt = true
      return
    }

    hasArt = false
    activeArtSource = ""
  }

  // ------------------------------------------------------------- Transport Controls
  function playPause() {
    if (!hasPlayer) return
    if (activePlayer.canTogglePlaying !== false) {
      activePlayer.togglePlaying()
    } else if (isPlaying && activePlayer.canPause !== false) {
      activePlayer.pause()
    } else if (!isPlaying && activePlayer.canPlay !== false) {
      activePlayer.play()
    } else if (mediaService) {
      mediaService.runAction("playPause", false)
    }
  }

  function skipPrevious() {
    if (!hasPlayer) return
    if (activePlayer.canGoPrevious !== false) {
      activePlayer.previous()
    } else if (mediaService) {
      mediaService.runAction("previous", false)
    }
  }

  function skipNext() {
    if (!hasPlayer) return
    if (activePlayer.canGoNext !== false) {
      activePlayer.next()
    } else if (mediaService) {
      mediaService.runAction("next", false)
    }
  }

  // ------------------------------------------------------------- Position Sync
  function syncPosition() {
    if (!hasPlayer || !activePlayer.positionSupported) {
      basePosition = 0
      currentPosition = 0
      baseTimestamp = 0
      return
    }
    basePosition = Math.max(0, activePlayer.position)
    baseTimestamp = Date.now()
    var len = root.trackLength
    currentPosition = len > 0 ? Math.min(basePosition, len) : basePosition
  }

  onActivePlayerChanged: {
    syncPosition()
    syncArt()
  }
  onTrackLengthChanged: syncPosition()
  onRawArtUrlChanged: syncArt()

  Component.onCompleted: {
    syncPosition()
    syncArt()
  }

  Connections {
    target: root.activePlayer
    function onPositionChanged() { root.syncPosition() }
    function onIsPlayingChanged() { root.syncPosition() }
    function onPlaybackStateChanged() { root.syncPosition() }
    function onTrackTitleChanged() {
      root.syncPosition()
      root.syncArt()
    }
    function onTrackArtistChanged() {
      root.syncPosition()
      root.syncArt()
    }
    function onLengthChanged() { root.syncPosition() }
  }

  Timer {
    id: interpolateTimer
    interval: 200
    repeat: true
    running: root.visible && root.hasPlayer && root.isPlaying && root.trackLength > 0
    onTriggered: {
      if (root.baseTimestamp > 0) {
        var elapsedSec = (Date.now() - root.baseTimestamp) / 1000.0
        var pos = root.basePosition + elapsedSec
        if (root.trackLength > 0) {
          pos = Math.min(pos, root.trackLength)
        }
        root.currentPosition = pos
      }
    }
  }

  visible: hasTrack
  implicitWidth: 381
  implicitHeight: hasTrack ? mainContainer.implicitHeight : 0
  width: implicitWidth
  height: implicitHeight

  // Reusable Album Art Component
  Component {
    id: albumArtComponent

    Item {
      width: root.artSize
      height: root.artSize

      // Fallback: generic music-note glyph (same one Omarchy's own stock
      // media bar widget uses), so it never implies a specific player/brand.
      Item {
        id: fallbackLogo
        anchors.fill: parent
        visible: !root.showAlbumArt

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Util.alpha(Color.lock.background, 0.5)
          border.color: Util.alpha(Color.lock.border, 0.35)
          border.width: 1
        }

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "󰝚"
          color: Color.lock.text
          font.family: Style.font.family
          font.pixelSize: Math.round(parent.width * 0.42)
        }
      }

      // Album Art: clipped circular image
      Item {
        id: albumArtItem
        anchors.fill: parent
        visible: root.showAlbumArt

        Item {
          id: artMask
          anchors.fill: parent
          visible: false
          layer.enabled: true

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "black"
          }
        }

        Image {
          id: artImage
          anchors.fill: parent
          source: root.activeArtSource
          fillMode: Image.PreserveAspectCrop
          visible: false
          asynchronous: true
          cache: false
          onStatusChanged: {
            root.artImageReady = (status === Image.Ready)
          }
          Component.onCompleted: {
            if (status === Image.Ready) root.artImageReady = true
          }
        }

        MultiEffect {
          anchors.fill: parent
          source: artImage
          maskEnabled: true
          maskSource: artMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.1
        }

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: "transparent"
          border.color: Util.alpha(Color.lock.border, 0.4)
          border.width: 1
        }
      }
    }
  }

  Column {
    id: mainContainer
    anchors.horizontalCenter: parent.horizontalCenter
    width: parent.width
    spacing: Style.space(12)

    // Album art when albumArtPosition === "top"
    Loader {
      id: topArtLoader
      active: root.effectiveAlbumArtPosition === "top"
      visible: active
      anchors.horizontalCenter: parent.horizontalCenter
      sourceComponent: albumArtComponent
    }

    // Horizontal block containing Left Art, Center Controls, Right Art
    Row {
      id: contentRow
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(14)

      // Album art when albumArtPosition === "left"
      Loader {
        id: leftArtLoader
        active: root.effectiveAlbumArtPosition === "left"
        visible: active
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: albumArtComponent
      }

      // Controls column
      Column {
        id: controlsCol
        anchors.verticalCenter: parent.verticalCenter
        width: root.effectiveAlbumArtPosition === "top"
          ? mainContainer.width
          : (mainContainer.width - root.artSize - contentRow.spacing)
        spacing: Style.space(8)

        Text {
          id: trackTextItem
          text: root.trackLabel
          color: Color.lock.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          maximumLineCount: 1
          width: parent.width
          horizontalAlignment: root.effectiveAlbumArtPosition === "top"
            ? Text.AlignHCenter
            : (root.effectiveAlbumArtPosition === "right" ? Text.AlignRight : Text.AlignLeft)
        }

        Rectangle {
          id: progressTrack
          width: parent.width
          height: 2
          radius: 1
          color: Util.alpha(Color.lock.border, 0.3)

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Math.round(parent.width * root.progress)
            radius: 1
            color: Color.lock.borderActive
          }
        }

        // Transport Controls
        Row {
          id: controlsRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(16)

          // Previous Button
          Item {
            id: prevBtn
            width: 28
            height: 28
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool enabled: root.activePlayer !== null && (root.activePlayer.canGoPrevious !== false)

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: prevMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.15) : "transparent"
            }

            Shape {
              anchors.centerIn: parent
              width: 14
              height: 14
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeWidth: 0
                fillColor: prevBtn.enabled
                  ? (prevMouse.containsMouse ? Color.lock.borderActive : Color.lock.text)
                  : Util.alpha(Color.lock.text, 0.3)
                startX: 1; startY: 2
                PathLine { x: 3; y: 2 }
                PathLine { x: 3; y: 12 }
                PathLine { x: 1; y: 12 }
                PathLine { x: 1; y: 2 }
              }

              ShapePath {
                strokeWidth: 0
                fillColor: prevBtn.enabled
                  ? (prevMouse.containsMouse ? Color.lock.borderActive : Color.lock.text)
                  : Util.alpha(Color.lock.text, 0.3)
                startX: 13; startY: 2
                PathLine { x: 4; y: 7 }
                PathLine { x: 13; y: 12 }
                PathLine { x: 13; y: 2 }
              }
            }

            MouseArea {
              id: prevMouse
              anchors.fill: parent
              hoverEnabled: prevBtn.enabled
              cursorShape: prevBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              enabled: prevBtn.enabled
              onClicked: root.skipPrevious()
            }
          }

          // Play / Pause Button
          Item {
            id: playPauseBtn
            width: 34
            height: 34
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool enabled: root.activePlayer !== null

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: playPauseMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.2) : Util.alpha(Color.lock.border, 0.1)
              border.color: Util.alpha(Color.lock.borderActive, playPauseMouse.containsMouse ? 0.6 : 0.25)
              border.width: 1
            }

            // Pause icon (when playing)
            Shape {
              anchors.centerIn: parent
              width: 14
              height: 14
              visible: root.isPlaying
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeWidth: 0
                fillColor: playPauseMouse.containsMouse ? Color.lock.borderActive : Color.lock.text
                startX: 2; startY: 2
                PathLine { x: 5.5; y: 2 }
                PathLine { x: 5.5; y: 12 }
                PathLine { x: 2; y: 12 }
                PathLine { x: 2; y: 2 }
              }

              ShapePath {
                strokeWidth: 0
                fillColor: playPauseMouse.containsMouse ? Color.lock.borderActive : Color.lock.text
                startX: 8.5; startY: 2
                PathLine { x: 12; y: 2 }
                PathLine { x: 12; y: 12 }
                PathLine { x: 8.5; y: 12 }
                PathLine { x: 8.5; y: 2 }
              }
            }

            // Play icon (when paused)
            Shape {
              anchors.centerIn: parent
              width: 14
              height: 14
              visible: !root.isPlaying
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeWidth: 0
                fillColor: playPauseMouse.containsMouse ? Color.lock.borderActive : Color.lock.text
                startX: 3; startY: 2
                PathLine { x: 13; y: 7 }
                PathLine { x: 3; y: 12 }
                PathLine { x: 3; y: 2 }
              }
            }

            MouseArea {
              id: playPauseMouse
              anchors.fill: parent
              hoverEnabled: playPauseBtn.enabled
              cursorShape: playPauseBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              enabled: playPauseBtn.enabled
              onClicked: root.playPause()
            }
          }

          // Next Button
          Item {
            id: nextBtn
            width: 28
            height: 28
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool enabled: root.activePlayer !== null && (root.activePlayer.canGoNext !== false)

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: nextMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.15) : "transparent"
            }

            Shape {
              anchors.centerIn: parent
              width: 14
              height: 14
              preferredRendererType: Shape.CurveRenderer

              ShapePath {
                strokeWidth: 0
                fillColor: nextBtn.enabled
                  ? (nextMouse.containsMouse ? Color.lock.borderActive : Color.lock.text)
                  : Util.alpha(Color.lock.text, 0.3)
                startX: 1; startY: 2
                PathLine { x: 10; y: 7 }
                PathLine { x: 1; y: 12 }
                PathLine { x: 1; y: 2 }
              }

              ShapePath {
                strokeWidth: 0
                fillColor: nextBtn.enabled
                  ? (nextMouse.containsMouse ? Color.lock.borderActive : Color.lock.text)
                  : Util.alpha(Color.lock.text, 0.3)
                startX: 11; startY: 2
                PathLine { x: 13; y: 2 }
                PathLine { x: 13; y: 12 }
                PathLine { x: 11; y: 12 }
                PathLine { x: 11; y: 2 }
              }
            }

            MouseArea {
              id: nextMouse
              anchors.fill: parent
              hoverEnabled: nextBtn.enabled
              cursorShape: nextBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              enabled: nextBtn.enabled
              onClicked: root.skipNext()
            }
          }
        }
      }

      // Album art when albumArtPosition === "right"
      Loader {
        id: rightArtLoader
        active: root.effectiveAlbumArtPosition === "right"
        visible: active
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: albumArtComponent
      }
    }
  }
}
