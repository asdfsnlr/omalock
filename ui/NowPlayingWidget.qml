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
  property string albumArtShape: ""
  property string localAlbumArtShape: ""

  readonly property string effectiveAlbumArtPosition: {
    var pos = (albumArtPosition || localAlbumArtPosition || "top").trim().toLowerCase()
    return (pos === "left" || pos === "right" || pos === "top") ? pos : "top"
  }

  readonly property string effectiveAlbumArtShape: (albumArtShape || localAlbumArtShape || "circle")

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
  readonly property real artShapeRadius: effectiveAlbumArtShape === "square" ? Style.cornerRadius : (artSize / 2)
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omalock"
  readonly property string artCachePath: pluginDir + "/album-art-cache.png"
  readonly property string bashBin: "/usr/bin/bash"

  // The only hosts whose images are ever fetched, matched on a label
  // boundary so a registered lookalike ("evilscdn.co") is never mistaken
  // for a subdomain. mpris:artUrl/trackArtUrl is metadata reported by
  // *any* MPRIS-capable player in the session and is read on the lock
  // screen before authentication, so this list is the entire SSRF
  // boundary: extend it only with hosts you'd trust to receive an
  // automatic, unauthenticated request from this machine.
  readonly property var artAllowedHosts: ["scdn.co"]

  function artHostAllowed(host) {
    for (var i = 0; i < root.artAllowedHosts.length; i++) {
      var allowed = root.artAllowedHosts[i]
      if (host === allowed) return true
      var suffix = "." + allowed
      if (host.length > suffix.length && host.slice(-suffix.length) === suffix) return true
    }
    return false
  }

  function artUnprintable(value) {
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i)
      if (code <= 0x20 || code === 0x7f) return true
    }
    return false
  }

  // Null unless `raw` is an https:// URL on an allowed host with no
  // userinfo/port (the oldest trick for making a URL read as a host it is
  // not) -- the only shape this widget will ever ask curl to fetch.
  function resolveRemoteArtUrl(raw) {
    if (!raw || root.artUnprintable(raw)) return null
    if (raw.indexOf("https://") !== 0) return null
    var authority = raw.substring(8).split(/[/?#]/)[0]
    if (!authority) return null
    if (authority.indexOf("@") !== -1 || authority.indexOf(":") !== -1) return null
    if (!root.artHostAllowed(authority.toLowerCase())) return null
    return raw
  }

  property string currentTargetUrl: ""
  property string activeArtSource: ""
  property bool hasArt: false
  property bool artImageReady: false
  property int cacheBuster: 0
  property string pendingArtUrl: ""

  FileView {
    id: fallbackSettingsFile
    path: Quickshell.env("HOME") + "/.config/omalock/settings.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && d.albumArtPosition) root.localAlbumArtPosition = String(d.albumArtPosition)
        if (d && d.albumArtShape) root.localAlbumArtShape = String(d.albumArtShape)
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  function getPlayerArtUrl() {
    // Capture into a local instead of re-reading the live activePlayer property
    // for each access below: the underlying MPRIS player can be torn down (the
    // Mpris watcher unregistering it) between one property read and the next,
    // and a stale reference dereferenced after that has crashed the whole
    // shell process (SIGSEGV), not just thrown a catchable QML TypeError —
    // reproduced live, correlated across every crash report so far with a
    // player disappearing right as this widget touched activePlayer.<field>.
    var p = activePlayer
    if (!p) return ""
    var url = ""
    if (p.trackArtUrl) {
      url = String(p.trackArtUrl)
    } else if (p.metadata && p.metadata["mpris:artUrl"]) {
      url = String(p.metadata["mpris:artUrl"])
    }
    return url ? url.trim() : ""
  }

  readonly property string rawArtUrl: getPlayerArtUrl()

  readonly property bool showAlbumArt: root.hasArt && root.artImageReady

  // One shell script, run with the URL and destination as $1/$2 so neither
  // ever reaches the command line as code. The host was already checked in
  // resolveRemoteArtUrl(); this still does not trust the response: no
  // redirects (a redirect would move the fetch off the host that was
  // checked), a hard size cap, and the format is read from the magic bytes
  // rather than trusted from a header or file extension. The download lands
  // in a randomly named temp file next to the destination and is `mv`'d
  // into place, so a symlink pre-placed at the fixed cache path can't
  // redirect the write.
  function artFetchScript() {
    return [
      "set -eu",
      "src=\"$1\"",
      "dest=\"$2\"",
      "max=8000000",
      "mkdir -p \"$(dirname -- \"$dest\")\" || exit 1",
      "tmp=$(mktemp \"${dest}.XXXXXX\") || exit 1",
      "trap 'rm -f \"$tmp\"' EXIT",
      "curl -sf --proto \"=https\" --max-redirs 0 --max-filesize \"$max\" --max-time 8 -o \"$tmp\" -- \"$src\" || exit 1",
      "size=$(wc -c < \"$tmp\") || exit 1",
      "[ \"$size\" -gt 0 ] && [ \"$size\" -le \"$max\" ] || exit 1",
      "sig=$(od -An -v -tx1 -N16 \"$tmp\" | tr -d ' \\n') || exit 1",
      "case \"$sig\" in",
      "  ffd8ff*|89504e470d0a1a0a*|474946383961*|474946383761*|424d*|52494646????????57454250*) ;;",
      "  *) exit 1 ;;",
      "esac",
      "mv -f \"$tmp\" \"$dest\""
    ].join("\n")
  }

  Process {
    id: artDownloader
    clearEnvironment: true
    environment: ({ "PATH": "/usr/bin" })
    onExited: function(code) {
      if (code === 0 && root.pendingArtUrl === root.currentTargetUrl) {
        root.cacheBuster += 1
        root.activeArtSource = Util.fileUrl(root.artCachePath) + "?v=" + root.cacheBuster
        root.hasArt = true
      } else if (root.pendingArtUrl === root.currentTargetUrl) {
        root.hasArt = false
        root.artImageReady = false
        root.activeArtSource = ""
      }
    }
  }

  // mpris:artUrl/trackArtUrl is metadata reported by *any* MPRIS-capable
  // player in the session (Spotify, a browser tab's extension, etc.) and
  // updates automatically, unauthenticated, on the lock screen. A remote
  // URL is only ever fetched when resolveRemoteArtUrl() accepts it (https,
  // no userinfo/port, host on the allowlist) and only through the bounded
  // script above -- everything else (including plain http://, or https to
  // a non-allowed host) is ignored rather than fetched.
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

    var remote = root.resolveRemoteArtUrl(raw)
    if (remote) {
      hasArt = false
      activeArtSource = ""
      root.pendingArtUrl = remote
      if (artDownloader.running) artDownloader.running = false
      artDownloader.command = [root.bashBin, "-c", root.artFetchScript(), "art-fetch", remote, root.artCachePath]
      artDownloader.running = true
      return
    }

    hasArt = false
    activeArtSource = ""
  }

  // ------------------------------------------------------------- Transport Controls
  function playPause() {
    var p = activePlayer
    if (!p) return
    if (p.canTogglePlaying !== false) {
      p.togglePlaying()
    } else if (isPlaying && p.canPause !== false) {
      p.pause()
    } else if (!isPlaying && p.canPlay !== false) {
      p.play()
    } else if (mediaService) {
      mediaService.runAction("playPause", false)
    }
  }

  function skipPrevious() {
    var p = activePlayer
    if (!p) return
    if (p.canGoPrevious !== false) {
      p.previous()
    } else if (mediaService) {
      mediaService.runAction("previous", false)
    }
  }

  function skipNext() {
    var p = activePlayer
    if (!p) return
    if (p.canGoNext !== false) {
      p.next()
    } else if (mediaService) {
      mediaService.runAction("next", false)
    }
  }

  // ------------------------------------------------------------- Position Sync
  function syncPosition() {
    // See getPlayerArtUrl() above for why activePlayer is captured into a
    // local instead of read multiple times here.
    var p = activePlayer
    if (!p || !p.positionSupported) {
      basePosition = 0
      currentPosition = 0
      baseTimestamp = 0
      return
    }
    basePosition = Math.max(0, p.position)
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
          radius: root.artShapeRadius
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
            radius: root.artShapeRadius
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
          radius: root.artShapeRadius
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
