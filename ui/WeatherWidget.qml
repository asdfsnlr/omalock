import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "file:///usr/share/omarchy/shell/plugins/panels/weather/Model.js" as WeatherModel

Item {
  id: root

  property bool hasWeather: false
  property string weatherGlyph: ""
  property string weatherTemp: ""
  property string weatherDesc: ""

  // Backward compatibility property; location is now driven by shared weather.json
  property string weatherLocation: ""

  // Temperature unit: "auto" | "metric" | "imperial"
  property string weatherUnit: "auto"
  property string localWeatherUnit: "auto"
  readonly property string activeWeatherUnit: (weatherUnit && weatherUnit !== "auto") ? weatherUnit : (localWeatherUnit || "auto")

  // Location configuration from shared ~/.local/state/omarchy/settings/weather.json
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name
  readonly property bool hasConfiguredCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude))) && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property string locationQuery: WeatherModel.wttrLocationQuery(configuredLocationState.name, configuredLocationState.latitude, configuredLocationState.longitude)

  // Weather data & reports
  property string wttrLocation: ""
  property var wttrReport: null
  property var openMeteoReport: null

  readonly property var areaInfo: wttrReport && wttrReport.nearest_area && wttrReport.nearest_area[0] ? wttrReport.nearest_area[0] : null
  readonly property string reportCountry: areaInfo && areaInfo.country && areaInfo.country[0] ? areaInfo.country[0].value : ""
  readonly property string reportLocation: configuredLocation || wttrLocation || (areaInfo && areaInfo.areaName && areaInfo.areaName[0] ? areaInfo.areaName[0].value : "")

  readonly property bool useImperial: WeatherModel.shouldUseImperial(activeWeatherUnit, Qt.locale().name, reportCountry)

  implicitWidth: hasWeather ? weatherRow.implicitWidth : 0
  implicitHeight: hasWeather ? weatherRow.implicitHeight : 0
  width: implicitWidth
  height: implicitHeight
  visible: hasWeather

  onLocationQueryChanged: {
    openMeteoReport = null
    wttrReport = null
    wttrLocation = ""
    refresh()
  }

  onActiveWeatherUnitChanged: updateDisplay()

  FileView {
    id: locationFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configuredLocationState = WeatherModel.parseLocationFile(text())
    onLoadFailed: root.configuredLocationState = WeatherModel.parseLocationFile("")
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  FileView {
    id: fallbackSettingsFile
    path: Quickshell.env("HOME") + "/.config/omalock/settings.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && d.weatherUnit !== undefined) root.localWeatherUnit = String(d.weatherUnit)
      } catch (e) {}
    }
  }

  function descForOpenMeteoCode(code) {
    var c = parseInt(String(code || "0"), 10)
    switch (c) {
      case 0: return "Clear"
      case 1: return "Mainly clear"
      case 2: return "Partly cloudy"
      case 3: return "Overcast"
      case 45: case 48: return "Fog"
      case 51: case 53: case 55: return "Drizzle"
      case 56: case 57: return "Freezing drizzle"
      case 61: case 63: case 65: return "Rain"
      case 66: case 67: return "Freezing rain"
      case 71: case 73: case 75: case 77: return "Snow"
      case 80: case 81: case 82: return "Showers"
      case 85: case 86: return "Snow showers"
      case 95: case 96: case 99: return "Thunderstorm"
      default: return ""
    }
  }

  function refresh() {
    if (hasConfiguredCoordinates) {
      fetchOpenMeteo(configuredLocationState.latitude, configuredLocationState.longitude)
      if (configuredLocation === "" && !locationProc.running) {
        locationProc.running = true
      }
    } else {
      if (!forecastProc.running) {
        forecastProc.running = true
      }
      if (locationQuery === "" && !locationProc.running) {
        locationProc.running = true
      }
    }
  }

  function fetchOpenMeteo(lat, lon) {
    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&forecast_days=4"
      + "&timezone=auto"
    dailyForecastProc.command = ["curl", "-fsS", "--max-time", "5", url]
    if (!dailyForecastProc.running) {
      dailyForecastProc.running = true
    }
  }

  Process {
    id: dailyForecastProc
    stdout: StdioCollector {
      id: dailyForecastStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (!root.wttrReport) root.hasWeather = false
        return
      }
      try {
        var parsed = JSON.parse(dailyForecastStdout.text)
        var cur = WeatherModel.openMeteoCurrentCondition(parsed)
        if (!cur) {
          if (!root.wttrReport) root.hasWeather = false
          return
        }
        root.openMeteoReport = parsed
        root.applyOpenMeteo(cur)
      } catch (e) {
        if (!root.wttrReport) root.hasWeather = false
      }
    }
  }

  function applyOpenMeteo(cur) {
    var imp = root.useImperial
    root.weatherTemp = (imp ? cur.temp_F : cur.temp_C) + "°" + (imp ? "F" : "C")
    root.weatherGlyph = WeatherModel.currentIcon(cur, root.weatherGlyph || "")
    if (root.wttrReport && root.wttrReport.current_condition && root.wttrReport.current_condition[0] && root.wttrReport.current_condition[0].weatherDesc && root.wttrReport.current_condition[0].weatherDesc[0]) {
      root.weatherDesc = root.wttrReport.current_condition[0].weatherDesc[0].value
    } else {
      root.weatherDesc = descForOpenMeteoCode(cur.openMeteoWeatherCode)
    }
    root.hasWeather = true
  }

  Process {
    id: forecastProc
    command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    stdout: StdioCollector {
      id: forecastStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (!root.openMeteoReport) root.hasWeather = false
        return
      }
      try {
        var parsed = JSON.parse(forecastStdout.text)
        if (!parsed || !parsed.current_condition || !parsed.current_condition[0]) {
          if (!root.openMeteoReport) root.hasWeather = false
          return
        }
        root.wttrReport = parsed
        if (!root.openMeteoReport) {
          var cur = parsed.current_condition[0]
          var imp = root.useImperial
          root.weatherTemp = (imp ? cur.temp_F : cur.temp_C) + "°" + (imp ? "F" : "C")
          root.weatherGlyph = WeatherModel.iconForCode(cur.weatherCode, false)
          root.weatherDesc = (cur.weatherDesc && cur.weatherDesc[0]) ? cur.weatherDesc[0].value : ""
          root.hasWeather = true
        }
        if (!root.hasConfiguredCoordinates && parsed.nearest_area && parsed.nearest_area[0]) {
          var lat = parseFloat(String(parsed.nearest_area[0].latitude || ""))
          var lon = parseFloat(String(parsed.nearest_area[0].longitude || ""))
          if (!isNaN(lat) && !isNaN(lon)) {
            root.fetchOpenMeteo(lat, lon)
          }
        }
      } catch (e) {
        if (!root.openMeteoReport) root.hasWeather = false
      }
    }
  }

  Process {
    id: locationProc
    command: ["curl", "-fsS", "--max-time", "4", "https://wttr.in/?format=%l"]
    stdout: StdioCollector {
      id: locationStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var raw = String(locationStdout.text || "").trim()
        if (raw) {
          root.wttrLocation = raw.split(",")[0]
        }
      }
    }
  }

  function updateDisplay() {
    if (openMeteoReport) {
      var cur = WeatherModel.openMeteoCurrentCondition(openMeteoReport)
      if (cur) applyOpenMeteo(cur)
    } else if (wttrReport && wttrReport.current_condition && wttrReport.current_condition[0]) {
      var curWttr = wttrReport.current_condition[0]
      var imp = useImperial
      weatherTemp = (imp ? curWttr.temp_F : curWttr.temp_C) + "°" + (imp ? "F" : "C")
    }
  }

  Timer {
    id: refreshTimer
    interval: 15 * 60 * 1000 // 15 minutes, matching system default
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()

  Row {
    id: weatherRow
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(6)
    visible: root.hasWeather

    Text {
      id: weatherText
      text: root.weatherGlyph + " " + root.weatherTemp + (root.weatherDesc ? " · " + root.weatherDesc : "")
      color: Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.05)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: "·"
      color: Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 1.05)
      anchors.verticalCenter: parent.verticalCenter
      visible: root.reportLocation !== ""
    }

    Row {
      visible: root.reportLocation !== ""
      spacing: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        text: "" // nf-fa-map_marker
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.body * 0.95)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: root.reportLocation
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.body * 1.05)
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }
}
