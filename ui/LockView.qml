import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  // A locked session blanks the displays after a few seconds. Nothing is
  // visible from then until the user wakes it, so a video must not keep
  // decoding through what is usually the longest part of a lock.
  property bool displaysBlank: false
  property bool powerSaverActive: false
  property string passwordText: ""
  property bool syncingPasswordText: false
  property var mediaService: null
  property var pluginSettings: null
  readonly property string avatarPosition: (root.pluginSettings && root.pluginSettings.avatarPosition) ? root.pluginSettings.avatarPosition : "top"
  readonly property string effectiveAvatarPath: root.pluginSettings ? (root.pluginSettings.avatarPath || "") : ""
  readonly property string networkWidgetPosition: (root.pluginSettings && root.pluginSettings.networkWidgetPosition) ? root.pluginSettings.networkWidgetPosition : "off"
  readonly property string powerControlsPosition: (root.pluginSettings && root.pluginSettings.powerControlsPosition) ? root.pluginSettings.powerControlsPosition : "off"
  readonly property int cornerMargin: Style.space(24)
  readonly property int cornerSpacing: Style.space(14)

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()
  signal previewDismissRequested()

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    BackgroundMedia {
      id: wallpaper
      anchors.fill: parent
      path: root.loadBackground ? root.backgroundPath : ""
      version: root.backgroundVersion
      playbackEnabled: root.loadBackground && !root.displaysBlank && !root.powerSaverActive
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper.video ? null : wallpaper
      visible: !wallpaper.video
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    // Qt's video output cannot be sampled by MultiEffect on every renderer.
    // Keep video wallpapers visible and darken them slightly for legibility.
    Rectangle {
      anchors.fill: wallpaper
      visible: wallpaper.video
      color: "#22000000"
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        if (!root.inputEnabled) {
          root.previewDismissRequested()
        } else {
          root.wakeRequested()
          root.forcePasswordFocus()
        }
      }
      onPositionChanged: root.wakeRequested()
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      color: Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "\u25CF"
        passwordMaskDelay: 0
        color: Color.lock.text
        selectionColor: Color.lock.selection
        selectedTextColor: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…" : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Color.lock.text : (root.failureMessage.length > 0 ? Color.lock.textError : Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }

    Column {
      id: topWidgets
      anchors.bottom: inputField.top
      anchors.bottomMargin: Style.space(36)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(12)

      AvatarWidget {
        id: topAvatar
        visible: (root.avatarPosition === "top") && hasAvatar
        anchors.horizontalCenter: parent.horizontalCenter
        avatarPath: (root.avatarPosition === "top") ? root.effectiveAvatarPath : ""
      }

      Row {
        id: horizontalBlock
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(20)

        AvatarWidget {
          id: leftAvatar
          visible: (root.avatarPosition === "left") && hasAvatar
          anchors.verticalCenter: parent.verticalCenter
          avatarPath: (root.avatarPosition === "left") ? root.effectiveAvatarPath : ""
        }

        Column {
          id: clockBlock
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          ClockWidget {
            anchors.horizontalCenter: parent.horizontalCenter
            dateFormat: root.pluginSettings ? (root.pluginSettings.dateFormat || "") : ""
            timeFormat: root.pluginSettings ? (root.pluginSettings.timeFormat || "") : ""
          }

          WeatherWidget {
            anchors.horizontalCenter: parent.horizontalCenter
            weatherLocation: root.pluginSettings ? (root.pluginSettings.weatherLocation || "") : ""
            weatherUnit: root.pluginSettings ? (root.pluginSettings.weatherUnit || "auto") : "auto"
          }
        }

        AvatarWidget {
          id: rightAvatar
          visible: (root.avatarPosition === "right") && hasAvatar
          anchors.verticalCenter: parent.verticalCenter
          avatarPath: (root.avatarPosition === "right") ? root.effectiveAvatarPath : ""
        }
      }
    }

    NowPlayingWidget {
      id: nowPlayingWidget
      anchors.top: inputField.bottom
      anchors.topMargin: Style.space(28)
      anchors.horizontalCenter: parent.horizontalCenter
      width: root.fieldWidth
      mediaService: root.mediaService
      albumArtPosition: (root.pluginSettings && root.pluginSettings.albumArtPosition) ? root.pluginSettings.albumArtPosition : "top"
    }

    // One Row per screen corner. Each corner widget reparents itself into
    // whichever Row matches its configured position; the Row lays out
    // whatever ends up inside it (one widget, both, or neither) left-to-right
    // with plain spacing, so two widgets sharing a corner sit side by side
    // instead of overlapping, with zero manual pixel math.
    Item {
      id: cornerLayer
      anchors.fill: parent

      Row {
        id: topLeftCorner
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.margins: root.cornerMargin
        spacing: root.cornerSpacing
      }
      Row {
        id: topRightCorner
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: root.cornerMargin
        spacing: root.cornerSpacing
      }
      Row {
        id: bottomLeftCorner
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.margins: root.cornerMargin
        spacing: root.cornerSpacing
      }
      Row {
        id: bottomRightCorner
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: root.cornerMargin
        spacing: root.cornerSpacing
      }
    }

    NetworkWidget {
      id: networkWidget
      visible: root.networkWidgetPosition !== "off"
      parent: {
        if (root.networkWidgetPosition === "top-left") return topLeftCorner
        if (root.networkWidgetPosition === "top-right") return topRightCorner
        if (root.networkWidgetPosition === "bottom-left") return bottomLeftCorner
        if (root.networkWidgetPosition === "bottom-right") return bottomRightCorner
        return cornerLayer
      }
    }

    PowerControlsWidget {
      id: powerControlsWidget
      visible: root.powerControlsPosition !== "off"
      interactive: root.inputEnabled
      parent: {
        if (root.powerControlsPosition === "top-left") return topLeftCorner
        if (root.powerControlsPosition === "top-right") return topRightCorner
        if (root.powerControlsPosition === "bottom-left") return bottomLeftCorner
        if (root.powerControlsPosition === "bottom-right") return bottomRightCorner
        return cornerLayer
      }
    }
  }
}
