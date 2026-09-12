import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons
import "ui"
import "file:///usr/share/omarchy/shell/plugins/services/media" as StockMedia

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string configDir: home + "/.config/omalock"
  readonly property string settingsPath: configDir + "/settings.json"
  readonly property string legacyPluginDir: home + "/.config/omarchy/plugins/slanger.lock"

  property var pluginSettings: ({
    albumArtPosition: "top",
    avatarPath: "",
    avatarPosition: "top",
    dateFormat: "dddd, MMMM d",
    timeFormat: "h:mm AP",
    weatherLocation: "",
    weatherUnit: "auto",
    networkWidgetPosition: "off"
  })
  property bool settingsWindowCreated: false
  property bool settingsWindowVisible: false

  readonly property var cornerPositions: ["off", "top-left", "top-right", "bottom-left", "bottom-right"]

  function validCornerPosition(value, fallback) {
    return (root.cornerPositions.indexOf(value) !== -1) ? value : fallback
  }

  function loadPluginSettings(raw) {
    var defaults = {
      albumArtPosition: "top",
      avatarPath: "",
      avatarPosition: "top",
      dateFormat: "dddd, MMMM d",
      timeFormat: "h:mm AP",
      weatherLocation: "",
      weatherUnit: "auto",
      networkWidgetPosition: "off"
    }
    if (!raw || String(raw).trim() === "") {
      root.pluginSettings = defaults
      return
    }
    try {
      var data = JSON.parse(raw)
      root.pluginSettings = {
        albumArtPosition: (data && (data.albumArtPosition === "left" || data.albumArtPosition === "right" || data.albumArtPosition === "top")) ? data.albumArtPosition : defaults.albumArtPosition,
        avatarPath: (data && data.avatarPath !== undefined) ? String(data.avatarPath) : defaults.avatarPath,
        avatarPosition: (data && (data.avatarPosition === "left" || data.avatarPosition === "right" || data.avatarPosition === "top")) ? data.avatarPosition : defaults.avatarPosition,
        dateFormat: (data && data.dateFormat !== undefined && String(data.dateFormat).trim() !== "") ? String(data.dateFormat) : defaults.dateFormat,
        timeFormat: (data && data.timeFormat !== undefined && String(data.timeFormat).trim() !== "") ? String(data.timeFormat) : defaults.timeFormat,
        weatherLocation: (data && data.weatherLocation !== undefined) ? String(data.weatherLocation) : defaults.weatherLocation,
        weatherUnit: (data && (data.weatherUnit === "metric" || data.weatherUnit === "imperial" || data.weatherUnit === "auto")) ? data.weatherUnit : defaults.weatherUnit,
        networkWidgetPosition: (data && data.networkWidgetPosition !== undefined) ? root.validCornerPosition(data.networkWidgetPosition, defaults.networkWidgetPosition) : defaults.networkWidgetPosition
      }
    } catch (e) {
      root.pluginSettings = defaults
    }
  }

  function savePluginSettings(data) {
    var next = {
      albumArtPosition: (data.albumArtPosition === "left" || data.albumArtPosition === "right" || data.albumArtPosition === "top") ? data.albumArtPosition : (root.pluginSettings.albumArtPosition || "top"),
      avatarPath: data.avatarPath !== undefined ? String(data.avatarPath) : root.pluginSettings.avatarPath,
      avatarPosition: (data.avatarPosition === "left" || data.avatarPosition === "right" || data.avatarPosition === "top") ? data.avatarPosition : (root.pluginSettings.avatarPosition || "top"),
      dateFormat: (data.dateFormat !== undefined && String(data.dateFormat).trim() !== "") ? String(data.dateFormat) : "dddd, MMMM d",
      timeFormat: (data.timeFormat !== undefined && String(data.timeFormat).trim() !== "") ? String(data.timeFormat) : "h:mm AP",
      weatherLocation: data.weatherLocation !== undefined ? String(data.weatherLocation) : root.pluginSettings.weatherLocation,
      weatherUnit: (data.weatherUnit === "metric" || data.weatherUnit === "imperial" || data.weatherUnit === "auto") ? data.weatherUnit : "auto",
      networkWidgetPosition: root.validCornerPosition(data.networkWidgetPosition, root.pluginSettings.networkWidgetPosition || "off")
    }
    root.pluginSettings = next
    pluginSettingsFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function toggleSettingsWindow() {
    if (!settingsWindowCreated) {
      settingsWindowCreated = true
      settingsWindowVisible = true
    } else {
      settingsWindowVisible = !settingsWindowVisible
    }
  }

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool displaysBlank: false
  // displaysBlank tracks what the lock asked for; Hyprland reports what each
  // panel actually did. While a video is on show the two are reconciled, so a
  // blank that failed keeps playing and a panel woken behind the lock's back
  // (a resume that kept the same outputs) resumes instead of freezing.
  property var monitorDpms: ({})
  property bool monitorDpmsKnown: false
  readonly property bool videoBackground: Util.isVideoPath(backgroundPath)
  property bool strandedLock: false
  property bool strandedLockResolved: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating
  StockMedia.Service {
    id: stockMediaService
  }

  readonly property var batteryService: shell && shell.services ? shell.firstPartyServiceFor("omarchy.battery") : null
  readonly property var mediaService: (shell && shell.services ? shell.firstPartyServiceFor("omarchy.media") : null) || stockMediaService
  readonly property bool powerSaverActive: batteryService ? batteryService.powerSaverOnBattery : false

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintRetryTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    root.displaysBlank = false
    root.monitorDpmsKnown = false
    if (!wakeProcess.running) wakeProcess.running = true
    if (lockRequested) armBlankTimer()
  }

  function runBlank() {
    root.displaysBlank = true
    root.monitorDpmsKnown = false
    if (!blankProcess.running) blankProcess.running = true
  }

  function screenBlank(screenName) {
    var name = String(screenName || "")
    if (!monitorDpmsKnown || !(name in monitorDpms)) return displaysBlank
    return !monitorDpms[name]
  }

  function applyMonitorDpms(text) {
    var monitors
    try {
      monitors = JSON.parse(String(text || ""))
    } catch (error) {
      return
    }
    if (!Array.isArray(monitors)) return

    var dpms = {}
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      if (monitor && monitor.name && !monitor.disabled) dpms[String(monitor.name)] = !!monitor.dpmsStatus
    }
    monitorDpms = dpms
    monitorDpmsKnown = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    if (!fingerprintPam.start()) {
      fingerprintAuthenticating = false
    }
  }

  function handleFingerprintFinished(result) {
    fingerprintAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      finishUnlock()
    } else if (fingerprintConfigured) {
      fingerprintRetryTimer.restart()
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
    }

    WlSessionLockSurface {
      id: lockSurface
      color: Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        displaysBlank: root.screenBlank(lockSurface.screen ? lockSurface.screen.name : "")
        powerSaverActive: root.powerSaverActive
        passwordText: root.enteredPassword
        mediaService: root.mediaService
        pluginSettings: root.pluginSettings
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      powerSaverActive: root.powerSaverActive
      passwordText: ""
      mediaService: root.mediaService
      pluginSettings: root.pluginSettings
      onPreviewDismissRequested: root.previewVisible = false
    }

    Item {
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.previewVisible = false
          event.accepted = true
        }
      }
    }
  }

  Loader {
    id: settingsWindowLoader
    active: root.settingsWindowCreated
    sourceComponent: SettingsWindow {
      visible: root.settingsWindowVisible
      previewActive: root.previewVisible
      pluginSettings: root.pluginSettings
      mediaService: root.mediaService
      onSaveRequested: function(data) {
        root.savePluginSettings(data)
        root.settingsWindowVisible = false
      }
      onApplyRequested: function(data) {
        root.savePluginSettings(data)
      }
      onCloseRequested: {
        root.settingsWindowVisible = false
      }
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.fingerprintAuthenticating = false
      if (root.lockRequested && root.fingerprintConfigured) fingerprintRetryTimer.restart()
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: 250
    repeat: false
    onTriggered: root.startFingerprint()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1 && fprintd-list \"$USER\" 2>/dev/null | grep -qi finger; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: {
      root.fingerprintConfigured = String(fingerprintCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.fingerprintConfigured) root.startFingerprint()
      else if (!root.fingerprintConfigured && fingerprintPam.active) fingerprintPam.abort()
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  // Quickshell exposes no DPMS signal, so the panel state is polled while a
  // video is the locked wallpaper. A wake or blank request drops the last
  // answer, so its optimistic state applies until the next poll confirms it.
  Process {
    id: monitorDpmsProcess
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: root.applyMonitorDpms(text)
    }
  }

  Timer {
    id: monitorDpmsTimer
    interval: 3000
    repeat: true
    triggeredOnStart: true
    running: root.locked && root.videoBackground
    onTriggered: {
      if (!monitorDpmsProcess.running) monitorDpmsProcess.running = true
    }
    onRunningChanged: {
      if (!running) root.monitorDpmsKnown = false
    }
  }

  Timer {
    id: idleBlankTimer
    interval: 5000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Only a password check in flight should hold the display up. The
      // fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` here would keep the panel lit until unlock.
      if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      // A panel coming back is a display turning on that runWake did not ask
      // for, so the blank state has to be given up here or a visible lock
      // wallpaper stays frozen until the next keypress.
      root.displaysBlank = false
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  FileView {
    id: pluginSettingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPluginSettings(text())
    onLoadFailed: root.loadPluginSettings("")
    onFileChanged: reload()
  }

  // Settings and cached images used to live inside the plugin's own source
  // directory (~/.config/omarchy/plugins/slanger.lock/), which meant user
  // state sat next to code that a plugin update could overwrite. Both now
  // live under ~/.config/omalock/ instead (same convention as omarazer's
  // ~/.config/omarazer/), separate from the plugin source entirely. This
  // one-time migration carries over settings.json and cached images from
  // the old location the first time this runs after the change, so an
  // existing install doesn't lose its configuration.
  Process {
    id: settingsMigrationProc
    onExited: pluginSettingsFile.reload()
  }

  function migrateLegacySettings() {
    var oldSettings = root.legacyPluginDir + "/settings.json"
    var newSettings = root.settingsPath
    var script = "mkdir -p " + JSON.stringify(root.configDir) + "\n" +
      "if [ ! -f " + JSON.stringify(newSettings) + " ] && [ -f " + JSON.stringify(oldSettings) + " ]; then\n" +
      "  cp " + JSON.stringify(oldSettings) + " " + JSON.stringify(newSettings) + "\n" +
      "fi\n" +
      "for f in avatar-cache.png album-art-cache.png; do\n" +
      "  old=" + JSON.stringify(root.legacyPluginDir) + "/\"$f\"\n" +
      "  new=" + JSON.stringify(root.configDir) + "/\"$f\"\n" +
      "  if [ ! -f \"$new\" ] && [ -f \"$old\" ]; then cp \"$old\" \"$new\"; fi\n" +
      "done"
    settingsMigrationProc.command = ["bash", "-c", script]
    settingsMigrationProc.running = true
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprintStatus()
    checkStrandedLock()
    migrateLegacySettings()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }

  IpcHandler {
    target: "slanger.lock"

    function openSettings(): string {
      root.toggleSettingsWindow()
      return "ok"
    }

    function openAvatarPicker(): string {
      if (!root.settingsWindowVisible) {
        root.toggleSettingsWindow()
      }
      if (settingsWindowLoader.item) {
        settingsWindowLoader.item.openAvatarPicker()
        return "ok"
      }
      return "not loaded"
    }

    function getSettings(): string {
      return JSON.stringify(root.pluginSettings)
    }

    function setSettings(jsonStr: string): string {
      try {
        var parsed = JSON.parse(jsonStr)
        root.savePluginSettings(parsed)
        return "ok"
      } catch (e) {
        return "error: " + e
      }
    }
  }
}
