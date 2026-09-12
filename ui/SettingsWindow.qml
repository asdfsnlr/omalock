import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

PanelWindow {
  id: root

  property var pluginSettings: null
  property var mediaService: null

  // Form properties
  property string formAvatarPath: ""
  property string avatarPosition: "top" // "top" | "left" | "right"
  property string albumArtPosition: "top" // "top" | "left" | "right"
  property string avatarMode: "file" // "file" | "url"
  property string weatherUnit: "auto" // "auto" | "metric" | "imperial"
  property string networkWidgetPosition: "off" // "off" | "top-left" | "top-right" | "bottom-left" | "bottom-right"

  // Shared system weather location (~/.local/state/omarchy/settings/weather.json)
  property var sharedLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string sharedLocationName: sharedLocationState.name

  FileView {
    id: sharedLocationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && typeof d === "object") {
          root.sharedLocationState = {
            name: (typeof d.name === "string") ? d.name.trim() : "",
            latitude: d.latitude !== undefined ? d.latitude : null,
            longitude: d.longitude !== undefined ? d.longitude : null
          }
        }
      } catch (e) {
        root.sharedLocationState = { name: "", latitude: null, longitude: null }
      }
    }
    onLoadFailed: {
      root.sharedLocationState = { name: "", latitude: null, longitude: null }
    }
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: sharedLocationFile.reload()
  }

  // Download state
  property string downloadStatus: ""
  property bool downloadError: false
  property bool isDownloading: false
  property int cacheBuster: 0

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omalock"
  readonly property string avatarCachePath: pluginDir + "/avatar-cache.png"

  // ── Trusted Child Process Paths & Environments ─────────────────────────
  readonly property string curlBin: "/usr/bin/curl"
  readonly property string zenityBin: "/usr/bin/zenity"
  readonly property string mvBin: "/usr/bin/mv"
  readonly property string rmBin: "/usr/bin/rm"
  readonly property var sessionEnv: ({
    "HOME": Quickshell.env("HOME") || "",
    "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || "",
    "WAYLAND_DISPLAY": Quickshell.env("WAYLAND_DISPLAY") || "",
    "DBUS_SESSION_BUS_ADDRESS": Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || ""
  })

  // A random, unguessable temp filename in the same directory as the final
  // cache file, so the download can be written there and atomically renamed
  // into place -- a predictable fixed path with a pre-placed symlink can no
  // longer redirect the write, since `mv` replaces the destination's
  // directory entry directly rather than following it.
  function randomTempPath(finalPath) {
    return finalPath + "." + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1e9).toString(36) + ".tmp"
  }

  readonly property string effectiveFormAvatarPath: {
    var p = String(formAvatarPath || "").trim()
    if (!p) return ""
    if (p.startsWith("~")) return Quickshell.env("HOME") + p.slice(1)
    return p
  }

  readonly property string formAvatarUrl: effectiveFormAvatarPath
    ? (Util.fileUrl(effectiveFormAvatarPath) + (cacheBuster > 0 ? "?v=" + cacheBuster : ""))
    : ""

  property bool previewActive: false
  readonly property bool suspended: zenityPicker.running || previewActive

  signal saveRequested(var data)
  signal applyRequested(var data)
  signal closeRequested()

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-lock-settings"
  WlrLayershell.layer: suspended ? WlrLayer.Bottom : WlrLayer.Overlay
  WlrLayershell.keyboardFocus: (root.visible && !suspended) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  function openAvatarPicker() {
    if (!zenityPicker.running) zenityPicker.running = true
  }

  readonly property var cornerKeys: ["off", "top-left", "top-right", "bottom-left", "bottom-right"]

  function validCornerKey(value) {
    return (root.cornerKeys.indexOf(value) !== -1) ? value : "off"
  }

  Timer {
    id: previewTimer
    interval: 1000
    running: root.visible
    repeat: true
    triggeredOnStart: true
    property date currentTime: new Date()
    onTriggered: currentTime = new Date()
  }

  function syncFromSettings() {
    if (!pluginSettings) return
    formAvatarPath = pluginSettings.avatarPath || ""
    avatarPosition = (pluginSettings.avatarPosition === "left" || pluginSettings.avatarPosition === "right" || pluginSettings.avatarPosition === "top")
      ? pluginSettings.avatarPosition
      : "top"
    albumArtPosition = (pluginSettings.albumArtPosition === "left" || pluginSettings.albumArtPosition === "right" || pluginSettings.albumArtPosition === "top")
      ? pluginSettings.albumArtPosition
      : "top"
    dateInput.text = pluginSettings.dateFormat || "dddd, MMMM d"
    timeInput.text = pluginSettings.timeFormat || "h:mm AP"
    weatherUnit = (pluginSettings.weatherUnit === "metric" || pluginSettings.weatherUnit === "imperial" || pluginSettings.weatherUnit === "auto")
      ? pluginSettings.weatherUnit
      : "auto"
    networkWidgetPosition = root.validCornerKey(pluginSettings.networkWidgetPosition)
    avatarMode = "file"
    fileInput.text = formAvatarPath
    urlInput.text = ""
    downloadStatus = ""
    downloadError = false
    isDownloading = false
  }

  onVisibleChanged: {
    if (visible) syncFromSettings()
  }

  Component.onCompleted: syncFromSettings()

  function save(closeAfter) {
    if (closeAfter === undefined) closeAfter = true
    var data = {
      avatarPath: root.effectiveFormAvatarPath,
      avatarPosition: root.avatarPosition,
      albumArtPosition: root.albumArtPosition,
      dateFormat: dateInput.text.trim() || "dddd, MMMM d",
      timeFormat: timeInput.text.trim() || "h:mm AP",
      weatherLocation: root.pluginSettings ? (root.pluginSettings.weatherLocation || "") : "",
      weatherUnit: root.weatherUnit,
      networkWidgetPosition: root.networkWidgetPosition
    }
    if (closeAfter) {
      root.saveRequested(data)
    } else {
      root.applyRequested(data)
    }
  }

  Process {
    id: zenityPicker
    command: [root.zenityBin, "--file-selection", "--title=Select Avatar Image", "--file-filter=Images (*.png *.jpg *.jpeg *.webp *.svg) | *.png *.jpg *.jpeg *.webp *.svg *.PNG *.JPG *.JPEG *.WEBP *.SVG"]
    clearEnvironment: true
    environment: root.sessionEnv
    stdout: StdioCollector {
      id: zenityStdout
      waitForEnd: true
    }
    onExited: function(code) {
      if (code === 0) {
        var picked = String(zenityStdout.text || "").trim()
        if (picked.length > 0) {
          root.formAvatarPath = picked
          fileInput.text = picked
          root.downloadStatus = ""
          root.downloadError = false
        }
      }
    }
  }

  // Downloads to a randomly named temp file, then atomically renames it
  // into place (see moveDownloadIntoPlace / cleanupFailedDownload) instead
  // of writing straight to the predictable avatarCachePath -- a symlink
  // pre-placed at that fixed path can no longer redirect the write.
  property string pendingDownloadTempPath: ""

  Process {
    id: urlDownloader
    command: []
    clearEnvironment: true
    onExited: function(code) {
      if (code === 0) {
        moveDownloadIntoPlace.command = [root.mvBin, "-T", root.pendingDownloadTempPath, root.avatarCachePath]
        moveDownloadIntoPlace.running = true
      } else {
        cleanupFailedDownload.command = [root.rmBin, "-f", root.pendingDownloadTempPath]
        cleanupFailedDownload.running = true
        root.isDownloading = false
        root.downloadError = true
        root.downloadStatus = "Download failed. Please check the URL or connection."
      }
    }
  }

  Process {
    id: moveDownloadIntoPlace
    clearEnvironment: true
    onExited: function(code) {
      root.isDownloading = false
      if (code === 0) {
        root.cacheBuster += 1
        root.formAvatarPath = root.avatarCachePath
        root.downloadError = false
        root.downloadStatus = "Avatar downloaded and cached successfully."
      } else {
        root.downloadError = true
        root.downloadStatus = "Download failed. Please check the URL or connection."
      }
    }
  }

  Process {
    id: cleanupFailedDownload
    clearEnvironment: true
  }

  function startDownload() {
    var rawUrl = urlInput.text.trim()
    if (!rawUrl.startsWith("http://") && !rawUrl.startsWith("https://")) {
      downloadError = true
      downloadStatus = "Please enter a valid URL starting with http:// or https://"
      return
    }
    downloadError = false
    downloadStatus = "Downloading image..."
    isDownloading = true
    root.pendingDownloadTempPath = root.randomTempPath(root.avatarCachePath)
    urlDownloader.command = [root.curlBin, "-sL", "--fail", "--max-time", "15", "-o", root.pendingDownloadTempPath, rawUrl]
    urlDownloader.running = true
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.65)
    visible: !root.suspended
  }

  MouseArea {
    anchors.fill: parent
    enabled: !root.suspended
    onClicked: root.closeRequested()
  }

  BorderSurface {
    id: card
    visible: !root.suspended
    width: 920
    height: formColumn.implicitHeight + card.contentTopInset + card.contentBottomInset
    anchors.centerIn: parent
    color: Color.lock.background
    borderSpec: Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, 2, "border-alpha")
    radius: Style.cornerRadius
    padding: Style.space(22)

    MouseArea {
      anchors.fill: parent
      onClicked: {}
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.closeRequested()
          event.accepted = true
        }
      }
    }

    Row {
      id: mainRow
      anchors.top: parent.top
      anchors.topMargin: card.contentTopInset
      anchors.left: parent.left
      anchors.leftMargin: card.contentLeftInset
      anchors.right: parent.right
      anchors.rightMargin: card.contentRightInset
      spacing: Style.space(20)

      // Left Column: Form
      Column {
        id: formColumn
        width: 500
        spacing: Style.space(12)

        Row {
          width: parent.width
          Text {
            text: "Lock Screen Settings"
            color: Color.lock.text
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }
        }

        // Avatar Section
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Avatar"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "Local image file or direct download URL"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // Mode Selector
          Row {
            spacing: Style.space(8)

            BorderSurface {
              id: modeFileBtn
              width: 110
              height: 28
              radius: Style.cornerRadius
              color: root.avatarMode === "file" ? Util.alpha(Color.lock.borderActive, 0.3) : Color.lock.background
              borderSpec: Border.surfaceSpec("lock", root.avatarMode === "file" ? "border-active" : "border", root.avatarMode === "file" ? Color.lock.borderActive : Color.lock.border, 1, "border-alpha")

              Text {
                anchors.centerIn: parent
                text: "Local File"
                color: root.avatarMode === "file" ? Color.lock.text : Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.avatarMode === "file"
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.avatarMode = "file"
              }
            }

            BorderSurface {
              id: modeUrlBtn
              width: 110
              height: 28
              radius: Style.cornerRadius
              color: root.avatarMode === "url" ? Util.alpha(Color.lock.borderActive, 0.3) : Color.lock.background
              borderSpec: Border.surfaceSpec("lock", root.avatarMode === "url" ? "border-active" : "border", root.avatarMode === "url" ? Color.lock.borderActive : Color.lock.border, 1, "border-alpha")

              Text {
                anchors.centerIn: parent
                text: "Image URL"
                color: root.avatarMode === "url" ? Color.lock.text : Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: root.avatarMode === "url"
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.avatarMode = "url"
              }
            }
          }

          // File Mode Row
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.avatarMode === "file"

            BorderSurface {
              width: parent.width - browseBtn.width - (clearBtn.visible ? clearBtn.width + Style.space(8) : 0) - Style.space(8)
              height: 36
              radius: Style.cornerRadius
              color: Color.lock.background
              borderSpec: Border.surfaceSpec("lock", fileInput.activeFocus ? "border-active" : "border", fileInput.activeFocus ? Color.lock.borderActive : Color.lock.border, fileInput.activeFocus ? 2 : 1, "border-alpha")

              TextInput {
                id: fileInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                activeFocusOnPress: true
                selectByMouse: true
                color: Color.lock.text
                selectionColor: Color.lock.selection
                selectedTextColor: Color.lock.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                clip: true

                Text {
                  anchors.fill: parent
                  verticalAlignment: Text.AlignVCenter
                  text: "e.g. /home/user/Pictures/avatar.png"
                  color: Color.lock.placeholder
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  visible: fileInput.text.length === 0 && !fileInput.activeFocus
                }

                onTextChanged: {
                  if (activeFocus) root.formAvatarPath = text.trim()
                }
              }
            }

            BorderSurface {
              id: browseBtn
              width: 90
              height: 36
              radius: Style.cornerRadius
              color: browseMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.25) : Color.lock.background
              borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")

              Text {
                anchors.centerIn: parent
                text: "Browse..."
                color: Color.lock.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: browseMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openAvatarPicker()
              }
            }

            BorderSurface {
              id: clearBtn
              width: 70
              height: 36
              radius: Style.cornerRadius
              visible: root.effectiveFormAvatarPath.length > 0
              color: clearMouse.containsMouse ? Util.alpha(Color.lock.borderError, 0.3) : "transparent"
              borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")

              Text {
                anchors.centerIn: parent
                text: "Clear"
                color: Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.formAvatarPath = ""
                  fileInput.text = ""
                  urlInput.text = ""
                  root.downloadStatus = ""
                  root.downloadError = false
                }
              }
            }
          }

          // URL Mode Row
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.avatarMode === "url"

            BorderSurface {
              width: parent.width - downloadBtn.width - (clearBtnUrl.visible ? clearBtnUrl.width + Style.space(8) : 0) - Style.space(8)
              height: 36
              radius: Style.cornerRadius
              color: Color.lock.background
              borderSpec: Border.surfaceSpec("lock", urlInput.activeFocus ? "border-active" : "border", urlInput.activeFocus ? Color.lock.borderActive : Color.lock.border, urlInput.activeFocus ? 2 : 1, "border-alpha")

              TextInput {
                id: urlInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                activeFocusOnPress: true
                selectByMouse: true
                color: Color.lock.text
                selectionColor: Color.lock.selection
                selectedTextColor: Color.lock.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                clip: true

                Text {
                  anchors.fill: parent
                  verticalAlignment: Text.AlignVCenter
                  text: "https://example.com/avatar.png"
                  color: Color.lock.placeholder
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  visible: urlInput.text.length === 0 && !urlInput.activeFocus
                }

                onAccepted: root.startDownload()
              }
            }

            BorderSurface {
              id: downloadBtn
              width: 90
              height: 36
              radius: Style.cornerRadius
              color: root.isDownloading ? Util.alpha(Color.lock.borderActive, 0.4) : (downloadMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.25) : Color.lock.background)
              borderSpec: Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, 1, "border-alpha")

              Text {
                anchors.centerIn: parent
                text: root.isDownloading ? "Fetching…" : "Download"
                color: Color.lock.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: downloadMouse
                anchors.fill: parent
                enabled: !root.isDownloading
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startDownload()
              }
            }

            BorderSurface {
              id: clearBtnUrl
              width: 70
              height: 36
              radius: Style.cornerRadius
              visible: root.effectiveFormAvatarPath.length > 0
              color: clearMouseUrl.containsMouse ? Util.alpha(Color.lock.borderError, 0.3) : "transparent"
              borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")

              Text {
                anchors.centerIn: parent
                text: "Clear"
                color: Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                id: clearMouseUrl
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.formAvatarPath = ""
                  fileInput.text = ""
                  urlInput.text = ""
                  root.downloadStatus = ""
                  root.downloadError = false
                }
              }
            }
          }

          // Download status / feedback
          Text {
            width: parent.width
            visible: root.downloadStatus.length > 0
            text: root.downloadStatus
            color: root.downloadError ? Color.lock.textError : Color.lock.borderActive
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Avatar Position Selector
        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Avatar Position"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "Layout relative to clock"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            spacing: Style.space(8)

            Repeater {
              model: [
                { key: "top", label: "Top" },
                { key: "left", label: "Left" },
                { key: "right", label: "Right" }
              ]

              delegate: BorderSurface {
                id: posBtn
                readonly property bool isSelected: root.avatarPosition === modelData.key
                width: 155
                height: 32
                radius: Style.cornerRadius
                color: isSelected ? Util.alpha(Color.lock.borderActive, 0.25) : (posMouse.containsMouse ? Util.alpha(Color.lock.border, 0.15) : Color.lock.background)
                borderSpec: Border.surfaceSpec("lock", isSelected ? "border-active" : "border", isSelected ? Color.lock.borderActive : Color.lock.border, isSelected ? 2 : 1, "border-alpha")

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: posBtn.isSelected ? Color.lock.text : Color.lock.placeholder
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: posBtn.isSelected
                }

                MouseArea {
                  id: posMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.avatarPosition = modelData.key
                }
              }
            }
          }
        }

        // Album Art Position Selector
        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Album Art Position"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "Layout relative to player controls"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            spacing: Style.space(8)

            Repeater {
              model: [
                { key: "top", label: "Top" },
                { key: "left", label: "Left" },
                { key: "right", label: "Right" }
              ]

              delegate: BorderSurface {
                id: artPosBtn
                readonly property bool isSelected: root.albumArtPosition === modelData.key
                width: 155
                height: 32
                radius: Style.cornerRadius
                color: isSelected ? Util.alpha(Color.lock.borderActive, 0.25) : (artPosMouse.containsMouse ? Util.alpha(Color.lock.border, 0.15) : Color.lock.background)
                borderSpec: Border.surfaceSpec("lock", isSelected ? "border-active" : "border", isSelected ? Color.lock.borderActive : Color.lock.border, isSelected ? 2 : 1, "border-alpha")

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: artPosBtn.isSelected ? Color.lock.text : Color.lock.placeholder
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: artPosBtn.isSelected
                }

                MouseArea {
                  id: artPosMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.albumArtPosition = modelData.key
                }
              }
            }
          }
        }

        // Date Format Field
        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Date Format"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "e.g. dddd, MMMM d (Default) or yyyy-MM-dd"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          BorderSurface {
            width: parent.width
            height: 36
            radius: Style.cornerRadius
            color: Color.lock.background
            borderSpec: Border.surfaceSpec("lock", dateInput.activeFocus ? "border-active" : "border", dateInput.activeFocus ? Color.lock.borderActive : Color.lock.border, dateInput.activeFocus ? 2 : 1, "border-alpha")

            TextInput {
              id: dateInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              activeFocusOnPress: true
              selectByMouse: true
              color: Color.lock.text
              selectionColor: Color.lock.selection
              selectedTextColor: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              clip: true

              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: "dddd, MMMM d"
                color: Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                visible: dateInput.text.length === 0 && !dateInput.activeFocus
              }
            }
          }
        }

        // Time Format Field
        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Time Format"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "e.g. h:mm AP (12h default) or HH:mm (24h)"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          BorderSurface {
            width: parent.width
            height: 36
            radius: Style.cornerRadius
            color: Color.lock.background
            borderSpec: Border.surfaceSpec("lock", timeInput.activeFocus ? "border-active" : "border", timeInput.activeFocus ? Color.lock.borderActive : Color.lock.border, timeInput.activeFocus ? 2 : 1, "border-alpha")

            TextInput {
              id: timeInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              activeFocusOnPress: true
              selectByMouse: true
              color: Color.lock.text
              selectionColor: Color.lock.selection
              selectedTextColor: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              clip: true

              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: "h:mm AP"
                color: Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                visible: timeInput.text.length === 0 && !timeInput.activeFocus
              }
            }
          }
        }

        // Weather Location Field (Shared with system weather)
        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Weather Location"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "Shared with system weather (omarchy.weather)"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          BorderSurface {
            width: parent.width
            height: 36
            radius: Style.cornerRadius
            color: Color.lock.background
            borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: "" // nf-fa-map_marker
                color: Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: root.sharedLocationName !== "" ? root.sharedLocationName : "Auto (detected by IP)"
                color: root.sharedLocationName !== "" ? Color.lock.text : Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          Text {
            text: "Configured via top bar weather panel or omarchy-weather-location"
            color: Color.lock.placeholder
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.caption * 0.95)
            font.italic: true
          }
        }

        // Temperature Unit Selector
        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Temperature Unit"
            color: Color.lock.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Row {
            spacing: Style.space(8)

            Repeater {
              model: [
                { key: "auto", label: "Auto (Locale)" },
                { key: "metric", label: "Celsius (°C)" },
                { key: "imperial", label: "Fahrenheit (°F)" }
              ]

              delegate: BorderSurface {
                id: unitBtn
                readonly property bool isSelected: root.weatherUnit === modelData.key
                width: 155
                height: 32
                radius: Style.cornerRadius
                color: isSelected ? Util.alpha(Color.lock.borderActive, 0.25) : (unitMouse.containsMouse ? Util.alpha(Color.lock.border, 0.15) : Color.lock.background)
                borderSpec: Border.surfaceSpec("lock", isSelected ? "border-active" : "border", isSelected ? Color.lock.borderActive : Color.lock.border, isSelected ? 2 : 1, "border-alpha")

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: unitBtn.isSelected ? Color.lock.text : Color.lock.placeholder
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: unitBtn.isSelected
                }

                MouseArea {
                  id: unitMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.weatherUnit = modelData.key
                }
              }
            }
          }
        }

        // Network Status Widget
        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              text: "Network Status"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              text: "Shows the active Wi-Fi/Ethernet connection in a screen corner"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: [
                { key: "off", label: "Off" },
                { key: "top-left", label: "Top Left" },
                { key: "top-right", label: "Top Right" },
                { key: "bottom-left", label: "Bottom Left" },
                { key: "bottom-right", label: "Bottom Right" }
              ]

              delegate: BorderSurface {
                id: netPosBtn
                readonly property bool isSelected: root.networkWidgetPosition === modelData.key
                width: 110
                height: 32
                radius: Style.cornerRadius
                color: isSelected ? Util.alpha(Color.lock.borderActive, 0.25) : (netPosMouse.containsMouse ? Util.alpha(Color.lock.border, 0.15) : Color.lock.background)
                borderSpec: Border.surfaceSpec("lock", isSelected ? "border-active" : "border", isSelected ? Color.lock.borderActive : Color.lock.border, isSelected ? 2 : 1, "border-alpha")

                Text {
                  anchors.centerIn: parent
                  text: modelData.label
                  color: netPosBtn.isSelected ? Color.lock.text : Color.lock.placeholder
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: netPosBtn.isSelected
                }

                MouseArea {
                  id: netPosMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.networkWidgetPosition = modelData.key
                }
              }
            }
          }
        }

        // Action Buttons
        Row {
          anchors.right: parent.right
          spacing: Style.space(12)

          BorderSurface {
            id: cancelBtn
            width: 100
            height: 36
            radius: Style.cornerRadius
            color: cancelMouse.containsMouse ? Util.alpha(Color.lock.border, 0.2) : "transparent"
            borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")

            Text {
              anchors.centerIn: parent
              text: "Cancel"
              color: Color.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: cancelMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeRequested()
            }
          }

          BorderSurface {
            id: saveBtn
            width: 110
            height: 36
            radius: Style.cornerRadius
            color: saveMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.45) : Util.alpha(Color.lock.borderActive, 0.3)
            borderSpec: Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, 2, "border-alpha")

            Text {
              anchors.centerIn: parent
              text: "Save"
              color: Color.lock.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }

            MouseArea {
              id: saveMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.save()
            }
          }
        }
      }

      // Vertical Separator
      Rectangle {
        id: colSeparator
        width: 1
        height: formColumn.implicitHeight
        color: Util.alpha(Color.lock.border, 0.3)
      }

      // Right Column: Live Preview Panel
      Column {
        id: rightColumn
        width: mainRow.width - formColumn.width - colSeparator.width - (2 * mainRow.spacing)
        height: formColumn.implicitHeight
        spacing: Style.space(12)

        Column {
          id: rightTitleCol
          width: parent.width
          spacing: Style.space(2)

          Text {
            text: "Live Preview"
            color: Color.lock.text
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            text: "Updates in real time as you edit"
            color: Color.lock.placeholder
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Miniature Lock Screen Container
        BorderSurface {
          id: previewContainer
          width: parent.width
          height: rightColumn.height - rightTitleCol.implicitHeight - fullPrevBtn.height - (2 * rightColumn.spacing)
          implicitHeight: height
          radius: Style.cornerRadius
          color: Color.lock.background
          borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")
          clip: true

          Rectangle {
            anchors.fill: parent
            color: "#161224"
            opacity: 0.85
          }

          // Centered widgets block
          Column {
            anchors.centerIn: parent
            spacing: Style.space(18)
            width: parent.width - Style.space(24)

            // Top-level widgets (Avatar + Clock + Date + Weather)
            Column {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(8)

              // Avatar when position === "top"
              Item {
                visible: (root.avatarPosition === "top") && previewAvatarImgTop.status === Image.Ready
                width: 52
                height: 52
                anchors.horizontalCenter: parent.horizontalCenter

                Item {
                  id: previewMaskTop
                  anchors.fill: parent
                  visible: false
                  layer.enabled: true
                  Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
                }

                Image {
                  id: previewAvatarImgTop
                  anchors.fill: parent
                  source: (root.avatarPosition === "top") ? root.formAvatarUrl : ""
                  fillMode: Image.PreserveAspectCrop
                  visible: false
                  asynchronous: true
                }

                MultiEffect {
                  anchors.fill: parent
                  source: previewAvatarImgTop
                  maskEnabled: true
                  maskSource: previewMaskTop
                  maskThresholdMin: 0.5
                  maskSpreadAtMin: 0.1
                }

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: "transparent"
                  border.color: Util.alpha(Color.lock.border, 0.5)
                  border.width: 1
                }
              }

              // Row containing Left Avatar, Clock Block, Right Avatar
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(14)

                // Avatar when position === "left"
                Item {
                  visible: (root.avatarPosition === "left") && previewAvatarImgLeft.status === Image.Ready
                  width: 52
                  height: 52
                  anchors.verticalCenter: parent.verticalCenter

                  Item {
                    id: previewMaskLeft
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
                  }

                  Image {
                    id: previewAvatarImgLeft
                    anchors.fill: parent
                    source: (root.avatarPosition === "left") ? root.formAvatarUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    visible: false
                    asynchronous: true
                  }

                  MultiEffect {
                    anchors.fill: parent
                    source: previewAvatarImgLeft
                    maskEnabled: true
                    maskSource: previewMaskLeft
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 0.1
                  }

                  Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.color: Util.alpha(Color.lock.border, 0.5)
                    border.width: 1
                  }
                }

                // Clock Block
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: {
                      var fmt = timeInput.text.trim() || "h:mm AP"
                      try { return Qt.formatTime(previewTimer.currentTime, fmt) }
                      catch(e) { return Qt.formatTime(previewTimer.currentTime, "h:mm AP") }
                    }
                    color: Color.lock.text
                    font.family: Style.font.family
                    font.pixelSize: Math.round(Style.font.heading * 1.6)
                    font.weight: Font.ExtraLight
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: {
                      var fmt = dateInput.text.trim() || "dddd, MMMM d"
                      try {
                        var d = Qt.formatDate(previewTimer.currentTime, fmt)
                        return d ? d.charAt(0).toUpperCase() + d.slice(1) : ""
                      } catch(e) { return Qt.formatDate(previewTimer.currentTime, "dddd, MMMM d") }
                    }
                    color: Color.lock.placeholder
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: {
                      var temp = root.weatherUnit === "metric" ? "22°C" : (root.weatherUnit === "imperial" ? "72°F" : "22°C / 72°F")
                      var loc = root.sharedLocationName || ""
                      return " " + temp + " · Mainly clear" + (loc ? " ·  " + loc : "")
                    }
                    color: Color.lock.placeholder
                    font.family: Style.font.family
                    font.pixelSize: Math.round(Style.font.caption * 0.9)
                  }
                }

                // Avatar when position === "right"
                Item {
                  visible: (root.avatarPosition === "right") && previewAvatarImgRight.status === Image.Ready
                  width: 52
                  height: 52
                  anchors.verticalCenter: parent.verticalCenter

                  Item {
                    id: previewMaskRight
                    anchors.fill: parent
                    visible: false
                    layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
                  }

                  Image {
                    id: previewAvatarImgRight
                    anchors.fill: parent
                    source: (root.avatarPosition === "right") ? root.formAvatarUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    visible: false
                    asynchronous: true
                  }

                  MultiEffect {
                    anchors.fill: parent
                    source: previewAvatarImgRight
                    maskEnabled: true
                    maskSource: previewMaskRight
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 0.1
                  }

                  Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.color: Util.alpha(Color.lock.border, 0.5)
                    border.width: 1
                  }
                }
              }
            }

            // Miniature Password Field
            BorderSurface {
              width: parent.width * 0.72
              height: 32
              anchors.horizontalCenter: parent.horizontalCenter
              color: Color.lock.background
              borderSpec: Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, 2, "border-alpha")
              radius: Style.cornerRadius

              Text {
                anchors.centerIn: parent
                text: "Enter Password"
                color: Color.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Now-playing preview: reuses the real widget with the real live
            // MPRIS session, so it only shows up here when it would also
            // show up on the actual lock screen (i.e. a player is active).
            NowPlayingWidget {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width * 0.72
              mediaService: root.mediaService
              albumArtPosition: root.albumArtPosition
            }
          }

          readonly property int cornerMargin: Style.space(10)
          readonly property int cornerSpacing: Style.space(8)

          // One Row per corner of the mockup. Each corner widget reparents
          // itself into whichever Row matches its configured position, so
          // two widgets sharing a corner lay out side by side automatically
          // (same technique as the real lock screen in LockView.qml).
          Row {
            id: previewTopLeftCorner
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.margins: previewContainer.cornerMargin
            spacing: previewContainer.cornerSpacing
          }
          Row {
            id: previewTopRightCorner
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: previewContainer.cornerMargin
            spacing: previewContainer.cornerSpacing
          }
          Row {
            id: previewBottomLeftCorner
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.margins: previewContainer.cornerMargin
            spacing: previewContainer.cornerSpacing
          }
          Row {
            id: previewBottomRightCorner
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.margins: previewContainer.cornerMargin
            spacing: previewContainer.cornerSpacing
          }

          // Network status corner preview (reuses the real widget, so it
          // reflects the actual live connection just like the lock screen).
          NetworkWidget {
            id: previewNetworkWidget
            visible: root.networkWidgetPosition !== "off"
            parent: {
              if (root.networkWidgetPosition === "top-left") return previewTopLeftCorner
              if (root.networkWidgetPosition === "top-right") return previewTopRightCorner
              if (root.networkWidgetPosition === "bottom-left") return previewBottomLeftCorner
              if (root.networkWidgetPosition === "bottom-right") return previewBottomRightCorner
              return previewContainer
            }
          }
        }

        // Fullscreen Preview Button
        BorderSurface {
          id: fullPrevBtn
          width: parent.width
          height: 36
          radius: Style.cornerRadius
          color: fullPrevMouse.containsMouse ? Util.alpha(Color.lock.borderActive, 0.2) : "transparent"
          borderSpec: Border.surfaceSpec("lock", "border", Color.lock.border, 1, "border-alpha")

          Text {
            anchors.centerIn: parent
            text: "Preview on Lock Screen"
            color: Color.lock.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            id: fullPrevMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              // Apply settings without closing the window so lock preview displays them
              root.save(false)
              Quickshell.execDetached(["omarchy-shell", "lock", "preview"])
            }
          }
        }
      }
    }
  }
}
