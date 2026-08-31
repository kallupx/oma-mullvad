import QtQuick
import Quickshell

ShellRoot {
  id: root
  property var service: null
  property int elapsed: 0
  property bool finished: false
  property bool removedRefreshStarted: false
  property string scenario: Quickshell.env("MULLVAD_PROBE_SCENARIO")

  Loader {
    id: loader
    source: "file://" + Quickshell.env("MULLVAD_PLUGIN_DIR") + "/Service.qml"
    onLoaded: {
      root.service = item
      item.readTimeoutMs = 800
      item.actionTimeoutMs = 800
      settle.start()
    }
  }

  Timer {
    id: settle
    interval: 100
    onTriggered: drain.start()
  }

  Timer {
    id: drain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        stop()
        if (root.scenario === "removed" && !root.removedRefreshStarted) {
          root.removedRefreshStarted = true
          root.elapsed = 0
          root.service._enqueueRead("probe", ["/definitely/missing/oma-mullvad-test"])
          start()
        } else if (root.scenario === "action-hang") {
          root.elapsed = 0
          root.service.logout()
          actionDrain.start()
        } else if (root.scenario === "login") {
          root.elapsed = 0
          root.service.login("1234567890123456")
          actionDrain.start()
        } else root.finish("")
      } else if (root.elapsed > 10000) root.finish("read queue did not drain")
    }
  }

  Timer {
    id: actionDrain
    interval: 50
    repeat: true
    onTriggered: {
      root.elapsed += interval
      if (!root.service.busy && root.service._readQueue.length === 0 && root.service._readKind === "") {
        stop()
        root.finish("")
      }
      else if (root.elapsed > 10000) root.finish("action did not drain")
    }
  }

  function finish(note) {
    if (finished) return
    finished = true
    console.log("PROBE_RESULT " + JSON.stringify({
      installed: service.installed,
      cliVersion: service.cliVersion,
      cliVersionSupported: service.cliVersionSupported,
      daemonRunning: service.daemonRunning,
      locations: service.locations.length,
      lastError: service.lastError,
      actionStatus: service.actionStatus,
      readWatchdogs: service._readWatchdogFiredCount,
      actionWatchdogs: service._actionWatchdogFiredCount,
      readOverflows: service._readOverflowCount,
      readChars: service._readOutputChars,
      scenario: root.scenario,
      removedRefreshStarted: root.removedRefreshStarted,
      note: note
    }))
    Qt.quit()
  }

  Timer {
    interval: 15000
    running: true
    onTriggered: root.finish("overall timeout")
  }
}
