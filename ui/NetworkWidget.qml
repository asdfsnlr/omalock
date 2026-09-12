import QtQuick
import Quickshell
import Quickshell.Networking
import qs.Commons

// Mirrors the connection detection used by Omarchy's own network bar widget
// (/usr/share/omarchy/shell/plugins/panels/network/Panel.qml): reads the
// live NetworkManager state via Quickshell.Networking rather than shelling
// out, and reuses the same signal-strength icon mapping from its Model.js.
Item {
  id: root

  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: findDevice(DeviceType.Wifi)
  readonly property var wifiNetworkObjects: (wifiDevice && wifiDevice.networks) ? wifiDevice.networks.values : []
  readonly property var connectedWifiNetwork: findConnectedWifiNetwork()
  readonly property var wiredDevice: findDevice(DeviceType.Wired)
  readonly property bool wiredConnected: !!(wiredDevice && wiredDevice.connected)
  readonly property string wiredIface: wiredDevice ? (wiredDevice.name || "") : ""

  readonly property string kind: wiredConnected ? "ethernet" : (connectedWifiNetwork ? "wifi" : "disconnected")

  readonly property int signalStrength: connectedWifiNetwork
    ? Math.round((connectedWifiNetwork.signalStrength || 0) * 100)
    : -1

  // Ethernet shows the network interface name (e.g. "enp4s0") rather than
  // the NetworkManager connection profile's display name.
  readonly property string connectionLabel: {
    if (kind === "wifi") return connectedWifiNetwork ? (connectedWifiNetwork.name || "") : ""
    if (kind === "ethernet") return wiredIface || "Ethernet"
    return ""
  }

  // Same icon set/thresholds as Model.js:wifiIconFor (20% bands, 5 glyphs).
  function wifiIconFor(strength) {
    var icons = ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
    var index = Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))
    return icons[index]
  }

  readonly property string glyph: kind === "wifi" ? wifiIconFor(signalStrength) : (kind === "ethernet" ? "󰈀" : "")
  readonly property bool hasConnection: kind !== "disconnected" && connectionLabel !== ""

  implicitWidth: hasConnection ? row.implicitWidth : 0
  implicitHeight: hasConnection ? row.implicitHeight : 0
  width: implicitWidth
  height: implicitHeight
  visible: hasConnection

  function findDevice(type) {
    var devices = networkDevices || []
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || device.type !== type) continue
      if (device.connected) return device
      if (!fallback) fallback = device
    }
    return fallback
  }

  function findConnectedWifiNetwork() {
    var networks = wifiNetworkObjects || []
    for (var i = 0; i < networks.length; i++) {
      if (networks[i] && networks[i].connected) return networks[i]
    }
    return null
  }

  Row {
    id: row
    spacing: Style.space(6)
    visible: root.hasConnection

    Text {
      textFormat: Text.PlainText
      text: root.glyph
      color: Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.05)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: root.connectionLabel
      color: Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.0)
      elide: Text.ElideRight
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
