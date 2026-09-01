import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.kallupx.oma-mullvad"

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var svc: shell ? shell.serviceFor(moduleName) : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property string stateIcon: !svc ? "connecting"
    : svc.state === "checking" ? "connecting"
    : !svc.installed || !svc.daemonRunning || svc.state === "error" ? "error"
    : svc.state === "blocked" ? "warning"
    : svc.tunnelDropWarning || (svc.loggedIn && svc.accountDaysRemaining >= 0 && svc.accountDaysRemaining <= 7) ? "warning"
    : svc.transitional ? "connecting"
    : svc.connected ? "connected" : "disconnected"
  readonly property color stateColor: stateIcon === "error" || stateIcon === "warning" ? urgent
    : svc && svc.connected ? foreground : Qt.darker(foreground, 1.55)
  readonly property string tunnelHint: svc && svc.active ? "Disconnect Mullvad VPN" : "Connect Mullvad VPN"
  readonly property string barTooltip: !svc ? "Checking Mullvad…"
    : !svc.installed ? "Mullvad CLI is not installed"
    : !svc.daemonRunning ? "Mullvad daemon is unavailable"
    : stateIcon === "error" ? "Mullvad tunnel error"
    : stateIcon === "warning" ? (svc.state === "blocked" ? "Mullvad is blocking network traffic"
      : svc.tunnelDropWarning ? "Mullvad tunnel dropped unexpectedly"
      : "Mullvad account credit expires soon")
    : tunnelHint

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    if (!svc || !panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.settings = root.settings
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.service = root.svc
  }

  function loadPanel() {
    if (!svc || panelLoader.status !== Loader.Null) return
    panelLoader.setSource(Qt.resolvedUrl("Panel.qml"), {
      bar: root.bar, settings: root.settings, anchorItem: button,
      hostWidget: root, service: root.svc
    })
  }

  function pushPollInterval() {
    if (!svc) return
    var seconds = Number(root.setting("refreshIntervalSec", 30)) || 30
    svc.pollInterval = Math.max(5000, Math.min(3600000, seconds * 1000))
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: loadPanel()
  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); pushPollInterval() }
  onSvcChanged: { loadPanel(); injectPanel(); pushPollInterval() }

  Loader {
    id: panelLoader
    active: root.svc !== null
    visible: false
    onLoaded: root.injectPanel()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        ThemeIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          state: root.stateIcon
          locked: root.svc ? (root.svc.connected || root.svc.state === "connecting") : false
          color: root.svc && root.svc.connected ? root.barForeground : Qt.darker(root.barForeground, 1.5)
          urgentColor: root.urgent
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.svc) root.svc.toggleTunnel() }
      else if (buttonCode === Qt.MiddleButton) { if (root.svc) root.svc.refreshAll() }
      else root.toggle()
    }
  }
}
