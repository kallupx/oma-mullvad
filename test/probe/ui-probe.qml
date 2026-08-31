import QtQuick
import Quickshell

ShellRoot {
  id: root
  property string pluginDir: Quickshell.env("MULLVAD_PLUGIN_DIR")
  property string scenario: Quickshell.env("MULLVAD_UI_SCENARIO")
  property var service: null
  property var widget: null
  property bool finished: false

  QtObject {
    id: appLibrary
    signal appsChanged()
    function sortedEntries(query) { return [] }
    function entryName(entry) { return "" }
    function entrySubtext(entry) { return "" }
    function iconSource(icon) { return "" }
    function refreshIcons() {}
  }

  QtObject {
    id: shell
    property var serviceInstance: null
    readonly property var appLibrary: appLibrary
    function serviceFor(id) {
      return id === "io.github.kallupx.oma-mullvad" ? serviceInstance : null
    }
    function updateEntryInline(id, entry) {}
  }

  QtObject {
    id: bar
    property color foreground: "#eeeeee"
    property color background: "#111111"
    property color urgent: "#ff5555"
    property color barForeground: "#eeeeee"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: false
    property var shell: shell
    property var activePopout: null
    property var clickTargets: []
    function run(command) {}
    function shellQuote(value) { return String(value) }
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { if (activePopout === owner) activePopout = null }
    function moduleWidgets(name) { return root.widget ? [root.widget] : [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  Loader {
    id: serviceLoader
    source: "file://" + root.pluginDir + "/Service.qml"
    onLoaded: {
      root.service = item
      shell.serviceInstance = item
      widgetLoader.active = true
    }
  }

  Loader {
    id: widgetLoader
    active: false
    source: "file://" + root.pluginDir + "/BarWidget.qml"
    onLoaded: {
      root.widget = item
      item.bar = bar
      item.settings = ({ refreshIntervalSec: 30 })
      settle.start()
    }
  }

  Timer {
    id: settle
    interval: 200
    onTriggered: waitForReady.start()
  }

  Timer {
    id: waitForReady
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      var idle = root.service && !root.service.busy
        && root.service._readQueue.length === 0 && root.service._readKind === ""
      if (idle && root.widget && root.widget._probePanelItem) {
        stop()
        root.runScenario()
      } else if (elapsed > 10000) root.finish("UI did not become ready")
    }
  }

  function runScenario() {
    if (scenario === "state-icons") {
      service.installed = true
      service.daemonRunning = true
      service.state = "connected"
      service.connected = true
      var connectedIcon = widget.stateIcon
      service.state = "error"
      service.connected = false
      service.tunnelDropWarning = true
      finish("", {
        panelLoaded: widget._probePanelItem !== null,
        panelServiceMatches: widget._probePanelItem.service === service,
        connectedIcon: connectedIcon,
        errorIcon: widget.stateIcon,
        errorTooltip: widget.barTooltip
      })
    } else if (scenario === "lifecycle") {
      var firstLoaded = widget._probePanelItem !== null
      shell.serviceInstance = null
      serviceLoader.active = false
      lifecycleWait.start()
      lifecycleWait.firstLoaded = firstLoaded
    } else finish("unknown scenario")
  }

  Timer {
    id: lifecycleWait
    property bool firstLoaded: false
    property int elapsed: 0
    interval: 50
    repeat: true
    onTriggered: {
      elapsed += interval
      if (root.widget.svc === null && root.widget._probePanelItem === null) {
        stop()
        root.finish("", {
          firstPanelLoaded: firstLoaded,
          loaderInactive: !root.widget._probePanelActive,
          loaderStatusNull: root.widget._probePanelStatus === Loader.Null,
          panelDestroyed: root.widget._probePanelItem === null
        })
      } else if (elapsed > 5000) root.finish("service lifecycle did not settle")
    }
  }

  function finish(note, values) {
    if (finished) return
    finished = true
    var result = { scenario: scenario, note: note }
    for (var key in (values || {})) result[key] = values[key]
    console.log("PROBE_RESULT " + JSON.stringify(result))
    Qt.quit()
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: root.finish("overall timeout")
  }
}
