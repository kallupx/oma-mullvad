import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root

  moduleName: "io.github.kallupx.oma-mullvad"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  property int pageIndex: 0
  property string locationQuery: ""
  property string appQuery: ""
  property var selectedLocation: null
  property var favoriteLocations: []
  property var recentLocations: []
  property var pendingConfirmation: null
  property bool syncingSettings: false
  readonly property bool cliReady: service.installed && service.daemonRunning
  readonly property var _probePageItem: pageLoader.item

  function pageAvailable(index) { return index === 0 || cliReady }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color stateColor: hostWidget ? hostWidget.stateColor : foreground
  readonly property string stateIcon: hostWidget ? hostWidget.stateIcon : "connecting"
  readonly property string tunnelHint: service.active ? "Disconnect Mullvad VPN" : "Connect Mullvad VPN"

  function arrayFrom(value) {
    if (!value || typeof value === "string" || typeof value.length !== "number") return []
    var result = []
    for (var i = 0; i < value.length; i++) result.push(value[i])
    return result
  }

  function locationKey(location) {
    if (!location) return ""
    return String(location.countryCode || "").toLowerCase() + "/" + String(location.cityCode || "").toLowerCase()
  }

  function normalizedLocation(location) {
    if (!location) return null
    return {
      countryCode: String(location.countryCode || "").toLowerCase(),
      cityCode: String(location.cityCode || "").toLowerCase(),
      country: String(location.country || location.countryCode || ""),
      city: String(location.city || location.cityCode || "")
    }
  }

  function locationFor(saved) {
    var key = locationKey(saved)
    var locations = arrayFrom(service.locations)
    for (var i = 0; i < locations.length; i++)
      if (locationKey(locations[i]) === key) return locations[i]
    return null
  }

  function isFavorite(location) {
    var key = locationKey(location)
    for (var i = 0; i < favoriteLocations.length; i++)
      if (locationKey(favoriteLocations[i]) === key) return true
    return false
  }

  function persistCollections(favorites, recents) {
    favoriteLocations = Model.normalizeFavorites(arrayFrom(favorites))
    recentLocations = Model.normalizeFavorites(arrayFrom(recents)).slice(0, 5)
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.favoriteLocations = favoriteLocations
    entry.recentLocations = recentLocations
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function toggleFavorite(location) {
    var normalized = normalizedLocation(location)
    if (!normalized || !normalized.countryCode || !normalized.cityCode) return
    var key = locationKey(normalized)
    var next = []
    var removed = false
    for (var i = 0; i < favoriteLocations.length; i++) {
      if (locationKey(favoriteLocations[i]) === key) removed = true
      else next.push(favoriteLocations[i])
    }
    if (!removed && next.length < 9) next.push(normalized)
    persistCollections(next, recentLocations)
  }

  function recordRecent(location) {
    var normalized = normalizedLocation(location)
    if (!normalized) return
    persistCollections(favoriteLocations, Model.addRecent(arrayFrom(recentLocations), normalized))
  }

  function chooseLocation(location, favoriteSwitch) {
    var resolved = locationFor(location) || location
    if (!resolved || !resolved.countryCode || !resolved.cityCode) return false
    if (!service.selectLocation(resolved.countryCode, resolved.cityCode, favoriteSwitch === true)) return false
    selectedLocation = resolved
    recordRecent(resolved)
    return true
  }

  function cycleFavorite(direction) {
    var available = Model.filterLocations(arrayFrom(service.locations), "", [], service.relayConstraints)
    var result = Model.cycleFavorite(arrayFrom(favoriteLocations), available, {
      countryCode: service.currentCountryCode,
      cityCode: service.currentCityCode
    }, direction)
    if (!result) return "no available favourites"
    var location = locationFor(result.favorite)
    if (!location) return "no available favourites"
    chooseLocation(location, true)
    return locationKey(location)
  }

  function chooseFavorite(number) {
    var index = Number(number) - 1
    if (index < 0 || index >= favoriteLocations.length || index !== Math.floor(index)) return "invalid favourite"
    var location = locationFor(favoriteLocations[index])
    if (!location) return "favourite unavailable"
    chooseLocation(location, true)
    return locationKey(location)
  }

  function filteredLocations() {
    return Model.filterLocations(arrayFrom(service.locations), locationQuery,
                                 arrayFrom(favoriteLocations), service.relayConstraints)
  }

  function locationOptions() {
    return Model.filterLocations(arrayFrom(service.locations), "", [], service.relayConstraints).map(function(location) {
      var servers = Model.filterServers(arrayFrom(location.servers), service.relayConstraints)
      var hints = []
      for (var i = 0; i < servers.length; i++)
        hints.push(String(servers[i].hostname || ""), String(servers[i].provider || ""))
      return {
        value: locationKey(location),
        label: location.city + ", " + location.country,
        description: locationKey(location) + (hints.length ? " · " + hints.join(" ") : "")
      }
    })
  }

  function favoriteOptions() {
    var result = [{ value: "", label: "Choose favourite" }]
    for (var i = 0; i < favoriteLocations.length; i++) {
      var location = locationFor(favoriteLocations[i])
      if (location) result.push({
        value: locationKey(location),
        label: String(i + 1) + ". " + location.city + ", " + location.country
      })
    }
    return result
  }

  function serverOptions(location) {
    if (!location) return []
    var result = [{ value: "", label: "Automatic server in " + location.city,
                    description: "Mullvad chooses a matching relay" }]
    var servers = Model.filterServers(arrayFrom(location.servers), service.relayConstraints)
    for (var i = 0; i < servers.length; i++) {
      var server = servers[i]
      result.push({
        value: String(server.hostname || ""),
        label: String(server.hostname || "Unknown relay"),
        description: [server.provider, server.ownership].filter(function(value) {
          return String(value || "") !== ""
        }).join(" · ")
      })
    }
    return result
  }

  function locationFromKey(key) {
    var parts = String(key || "").split("/")
    if (parts.length !== 2) return null
    return locationFor({ countryCode: parts[0], cityCode: parts[1] })
  }

  function constraintKey(constraint) {
    if (!constraint || typeof constraint !== "object") return String(constraint || "")
    if (constraint.countryCode && constraint.cityCode)
      return String(constraint.countryCode).toLowerCase() + "/" + String(constraint.cityCode).toLowerCase()
    return ""
  }

  function relayTargetLabel() {
    var constraint = (service.relayConstraints || {}).location || ({})
    var type = String(constraint.type || "any")
    if (type === "unknown") return "a relay constraint configured in Mullvad"
    var location = locationFor(constraint)
    if (type === "hostname") {
      var suffix = location ? " · " + location.city + ", " + location.country : ""
      return String(constraint.hostname || "specific relay") + suffix
    }
    if (type === "city")
      return location ? location.city + ", " + location.country
        : String(constraint.countryCode || "").toUpperCase() + "/" + String(constraint.cityCode || "").toUpperCase()
    if (type === "country") {
      var locations = arrayFrom(service.locations)
      for (var i = 0; i < locations.length; i++)
        if (String(locations[i].countryCode || "") === String(constraint.countryCode || ""))
          return locations[i].country + " · any city"
      return String(constraint.countryCode || "").toUpperCase() + " · any city"
    }
    return "an automatic Mullvad relay"
  }

  function targetMapLocation() {
    var constraint = (service.relayConstraints || {}).location || ({})
    var exact = locationFor(constraint)
    if (exact) return exact
    if (String(constraint.type || "") !== "country") return null
    var locations = arrayFrom(service.locations)
    for (var i = 0; i < locations.length; i++)
      if (String(locations[i].countryCode || "") === String(constraint.countryCode || "")) return locations[i]
    return null
  }

  function connectedMapLocation() {
    if (!service.connected) return null
    var exact = locationFor({ countryCode: service.currentCountryCode, cityCode: service.currentCityCode })
    if (exact) return exact
    var locations = arrayFrom(service.locations)
    for (var i = 0; i < locations.length; i++)
      if (String(locations[i].country || "").toLowerCase() === String(service.country || "").toLowerCase()
          && String(locations[i].city || "").toLowerCase() === String(service.city || "").toLowerCase()) return locations[i]
    return null
  }

  function selectedServerValue(location) {
    var constraint = (service.relayConstraints || {}).location || ({})
    return location && String(constraint.type || "") === "hostname"
      && locationKey(location) === constraintKey(constraint)
      ? String(constraint.hostname || "") : ""
  }

  function dnsFlags(changed, value) {
    var current = service.dns || ({})
    var flags = {
      blockAds: !!current.blockAds,
      blockTrackers: !!current.blockTrackers,
      blockMalware: !!current.blockMalware,
      blockAdultContent: !!current.blockAdultContent,
      blockGambling: !!current.blockGambling,
      blockSocialMedia: !!current.blockSocialMedia
    }
    flags[changed] = value
    return flags
  }

  function appRows() {
    if (!bar || !bar.shell || !bar.shell.appLibrary) return []
    var source = bar.shell.appLibrary.sortedEntries(appQuery)
    var result = []
    for (var i = 0; i < source.length && result.length < 30; i++) {
      var entry = source[i].entry || source[i]
      if (entry && entry.id) result.push(entry)
    }
    return result
  }

  function excludedApps() {
    if (!bar || !bar.shell || !bar.shell.appLibrary) return []
    var library = bar.shell.appLibrary
    var source = library.sortedEntries("")
    var result = []
    for (var i = 0; i < source.length; i++) {
      var entry = source[i].entry || source[i]
      if (!entry) continue
      var firstWord = String(entry.execString || "").trim().split(/\s+/)[0] || ""
      var execBase = firstWord.split("/").pop()
      if (execBase) result.push({ name: Model.plainText(library.entryName(entry), 128), execBase: execBase })
    }
    return result
  }

  function excludedGroups() {
    return Model.groupExcludedProcesses(arrayFrom(service.excludedProcesses), excludedApps())
  }

  function showPage(index) {
    var target = Math.max(0, Math.min(3, index))
    if (!pageAvailable(target)) return
    pageIndex = target
    if (target === 3) service.refreshExcluded()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function movePage(delta) {
    var next = pageIndex
    for (var i = 0; i < 4; i++) {
      next = (next + delta + 4) % 4
      if (pageAvailable(next)) { showPage(next); return }
    }
  }

  onCliReadyChanged: if (!pageAvailable(pageIndex)) showPage(0)

  function moveScroll(delta) {
    if (!pageFlick) return
    pageFlick.contentY = Math.max(0, Math.min(pageFlick.contentHeight - pageFlick.height,
                                             pageFlick.contentY + delta * Style.space(42)))
  }

  function focusNext(direction) {
    var next = keyCatcher.nextItemInFocusChain(direction > 0)
    if (next) next.forceActiveFocus()
  }

  function ensureFocusedItemVisible(item) {
    if (!item || !pageFlick || !pageLoader.item) return
    var ancestor = item
    var insidePage = false
    while (ancestor) {
      if (ancestor === pageLoader.item) { insidePage = true; break }
      ancestor = ancestor.parent
    }
    if (!insidePage) return
    Qt.callLater(function() {
      if (!item || !pageFlick) return
      var point = item.mapToItem(pageFlick.contentItem, 0, 0)
      var margin = Style.space(8)
      if (point.y < pageFlick.contentY + margin)
        pageFlick.contentY = Math.max(0, point.y - margin)
      else if (point.y + item.height > pageFlick.contentY + pageFlick.height - margin)
        pageFlick.contentY = Math.min(Math.max(0, pageFlick.contentHeight - pageFlick.height),
                                      point.y + item.height + margin - pageFlick.height)
    })
  }

  function confirmAction(message, callback) {
    pendingConfirmation = callback
    confirmDialog.message = message
    confirmDialog.opened = true
  }

  function syncInlineSettings() {
    if (syncingSettings) return
    syncingSettings = true
    favoriteLocations = Model.normalizeFavorites(arrayFrom(setting("favoriteLocations", [])))
    recentLocations = Model.normalizeFavorites(arrayFrom(setting("recentLocations", []))).slice(0, 5)
    syncingSettings = false
  }

  onSettingsChanged: syncInlineSettings()
  onOpenedChanged: if (opened) {
    pageFlick.contentY = 0
    service.refreshAll()
    if (bar && bar.shell && bar.shell.appLibrary && bar.shell.appLibrary.refreshIcons) bar.shell.appLibrary.refreshIcons()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  Component.onCompleted: syncInlineSettings()

  Timer {
    interval: 5000
    running: root.opened && root.pageIndex === 3
    repeat: true
    onTriggered: service.refreshExcluded()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refreshAll(); return "ok" }
    function status(): string {
      return JSON.stringify({ state: service.state, country: service.country, city: service.city, hostname: service.hostname, ip: service.ip })
    }
    function connect(): string { service.connectTunnel(); return "ok" }
    function disconnect(): string { service.disconnectTunnel(); return "ok" }
    function toggleTunnel(): string { service.toggleTunnel(); return "ok" }
    function excluded(): string { return JSON.stringify(root.excludedGroups()) }
    function nextFavorite(): string { return root.cycleFavorite(1) }
    function previousFavorite(): string { return root.cycleFavorite(-1) }
    function favorite(index: string): string { return root.chooseFavorite(index) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    readonly property real hostAvailableCardHeight: {
      if (screenH <= 0 || !bar) return availableCardHeight
      var horizontal = barPos === "top" || barPos === "bottom"
      return Math.max(120, screenH - (horizontal
        ? bar.barSize + gap + margin
        : margin * 2))
    }
    contentWidth: panel.fittedContentWidth(Style.space(500), Style.space(560))
    contentHeight: Math.max(121, Math.round(Math.min(
      hostAvailableCardHeight,
      Style.space(680),
      Math.max(Style.space(240), panelColumn.implicitHeight + verticalContentInset))))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      readonly property Item focusedItem: keyCatcher.Window.window
        ? (keyCatcher.Window.window.activeFocusItem || null) : null
      blocked: confirmDialog.opened === true || (focusedItem !== null && focusedItem !== keyCatcher)
      onFocusedItemChanged: root.ensureFocusedItemVisible(focusedItem)
      onMoveRequested: function(dx, dy) {
        if (dx) root.movePage(dx)
        else root.moveScroll(dy)
      }
      onActivateRequested: if (root.cliReady) service.toggleTunnel()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.focusNext(direction) }
      onTextKey: function(text) {
        if (text === "1") root.showPage(0)
        else if (text === "2") root.showPage(1)
        else if (text === "3") root.showPage(2)
        else if (text === "4") root.showPage(3)
        else if (text === "r" || text === "R") service.refreshAll()
        else if ((text === "t" || text === "T") && root.cliReady) service.toggleTunnel()
        else if ((text === "n" || text === "N") && root.cliReady) root.cycleFavorite(1)
        else if ((text === "p" || text === "P") && root.cliReady) root.cycleFavorite(-1)
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(12)

        RowLayout {
          width: parent.width
          spacing: Style.spacing.xs

          Repeater {
            model: ["Overview", "Locations", "Advanced", "Excluded"]
            Button {
              required property string modelData
              required property int index
              Layout.fillWidth: true
              text: modelData
              selected: root.pageIndex === index
              enabled: root.pageAvailable(index)
              opacity: root.pageAvailable(index) ? 1 : 0.35
              focusable: root.pageAvailable(index)
              foreground: root.foreground
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.md
              onClicked: root.showPage(index)
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Flickable {
          id: pageFlick
          width: parent.width
          height: Math.min(pageLoader.item ? pageLoader.item.implicitHeight : 0,
                           Style.space(590),
                           Math.max(Style.space(180), panel.hostAvailableCardHeight - panel.verticalContentInset - Style.space(60)))
          implicitHeight: height
          contentWidth: width
          contentHeight: pageLoader.item ? pageLoader.item.implicitHeight : 0
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Loader {
            id: pageLoader
            width: pageFlick.width
            sourceComponent: root.pageIndex === 0 ? overviewPage
              : root.pageIndex === 1 ? locationsPage
              : root.pageIndex === 2 ? advancedPage : excludedPage
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        foreground: root.foreground
        background: Color.popups.background
        focus: opened
        onOpenedChanged: if (opened) Qt.callLater(function() { confirmDialog.forceActiveFocus() })
        Keys.onPressed: function(event) {
          if (handleKey(event)) event.accepted = true
        }
        onCanceled: {
          opened = false
          root.pendingConfirmation = null
          keyCatcher.forceActiveFocus()
        }
        onConfirmed: {
          var callback = root.pendingConfirmation
          opened = false
          root.pendingConfirmation = null
          if (callback) callback()
          keyCatcher.forceActiveFocus()
        }
      }
    }
  }

  Component {
    id: overviewPage

    Column {
      width: pageFlick.width
      spacing: Style.space(12)
      Keys.onEscapePressed: root.close()

      Item {
        id: overviewHeader
        width: parent.width
        implicitHeight: overviewHero.implicitHeight
        readonly property bool tunnelChecked: service.active
        readonly property bool tunnelBusy: service.busy || !service.installed || !service.daemonRunning
        readonly property string tunnelTooltip: root.cliReady ? root.tunnelHint
          : !service.installed ? "Install Mullvad VPN first" : "Start the Mullvad daemon first"
        readonly property color controlAccent: root.accent
        function toggleTunnel() { if (!tunnelBusy) service.toggleTunnel() }

        PanelHero {
          id: overviewHero
          width: parent.width
          title: service.installed ? "Mullvad VPN" : "Mullvad unavailable"
          meta: service.installed ? service.statusText : "Install Mullvad VPN 2026.4 to enable this widget"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: service.connected ? 1 : 0.55
          iconComponent: Component {
            ThemeIcon {
              iconSize: Style.font.display
              state: root.stateIcon
              color: root.stateColor
              urgentColor: root.urgent
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: tunnelSwitch
              checked: overviewHeader.tunnelChecked
              busy: overviewHeader.tunnelBusy
              enabled: root.cliReady
              opacity: root.cliReady ? 1 : 0.35
              activeFocusOnTab: root.cliReady
              hasCursor: activeFocus
              foreground: overviewHero.foreground
              accent: overviewHeader.controlAccent
              Keys.onReturnPressed: if (!busy) toggled()
              Keys.onEnterPressed: if (!busy) toggled()
              Keys.onSpacePressed: if (!busy) toggled()
              onToggled: overviewHeader.toggleTunnel()

              PanelToolTip {
                visible: tunnelSwitch.containsMouse
                text: overviewHeader.tunnelTooltip
                fontFamily: overviewHero.fontFamily
              }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: service.connected && (service.country !== "" || service.ip !== "")
        width: parent.width
        text: "Exit: " + [service.city, service.country, service.hostname, service.ip].filter(function(value) { return String(value || "") !== "" }).join(" · ")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: service.lastError !== ""
        width: parent.width
        text: service.lastError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      BorderSurface {
        visible: !service.installed || !service.daemonRunning
        width: parent.width
        implicitHeight: unavailableText.implicitHeight + Style.space(24)
        color: Style.normalFillFor(root.foreground, Color.accent)
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        radius: Style.cornerRadius

        Text {
          textFormat: Text.PlainText
          id: unavailableText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(12)
          text: service.state === "checking"
            ? "Checking for Mullvad VPN…"
            : !service.installed
            ? "Mullvad CLI was not found. Use the install button below or install Mullvad with your preferred method."
            : "The Mullvad daemon is unavailable. Start mullvad-daemon, then press refresh."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }

      Button {
        visible: !service.installed && service.state === "unavailable"
        width: parent.width
        text: "Install Mullvad VPN (AUR)"
        bordered: true
        focusable: true
        foreground: root.foreground
        onClicked: root.confirmAction(
          "Install the mullvad-vpn-bin package from the AUR? A terminal will open and ask for your sudo password.",
          function() {
            Quickshell.execDetached([
              "omarchy-launch-floating-terminal-with-presentation",
              "omarchy pkg aur add mullvad-vpn-bin"
            ])
          })
      }

      BorderSurface {
        visible: service.installed && !service.cliVersionSupported
        width: parent.width
        implicitHeight: versionWarningText.implicitHeight + Style.space(20)
        color: Util.alpha(root.urgent, 0.10)
        borderSpec: Border.flat(root.urgent, Style.normalBorderWidth)
        radius: Style.cornerRadius

        Text {
          id: versionWarningText
          textFormat: Text.PlainText
          anchors.fill: parent
          anchors.margins: Style.space(10)
          text: service.cliVersion !== ""
            ? "Mullvad CLI " + service.cliVersion + " is untested with this plugin; some settings may display incorrectly."
            : "The Mullvad CLI version could not be identified; some settings may display incorrectly."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      BorderSurface {
        visible: service.tunnelDropWarning || (service.loggedIn && service.accountDaysRemaining >= 0 && service.accountDaysRemaining <= 7)
        width: parent.width
        implicitHeight: warningText.implicitHeight + Style.space(20)
        color: Util.alpha(root.urgent, 0.10)
        borderSpec: Border.flat(root.urgent, Style.normalBorderWidth)
        radius: Style.cornerRadius

        Text {
          textFormat: Text.PlainText
          id: warningText
          anchors.fill: parent
          anchors.margins: Style.space(10)
          text: service.tunnelDropWarning
            ? "Tunnel dropped unexpectedly. Review the daemon state before reconnecting."
            : "Mullvad account credit expires " + (service.accountExpiry || "soon") + "."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      BorderSurface {
        id: relayMap
        visible: root.cliReady
        width: parent.width
        height: Math.round(width * 0.50)
        color: Util.alpha(root.foreground, 0.025)
        borderSpec: Border.flat(Util.alpha(root.foreground, 0.16), Style.normalBorderWidth)
        radius: Style.cornerRadius

        WorldMap {
          anchors.fill: parent
          anchors.margins: Style.space(8)
          locations: service.locations
          selectedPoint: root.targetMapLocation()
          connectedPoint: root.connectedMapLocation()
          foreground: root.foreground
          accent: root.accent
        }
      }

      OmaDropdown {
        visible: root.cliReady && root.favoriteOptions().length > 1
        width: parent.width
        label: "Quick select favourite"
        options: root.favoriteOptions()
        value: root.isFavorite((service.relayConstraints || {}).location)
          ? root.constraintKey((service.relayConstraints || {}).location) : ""
        enabled: !service.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(value) {
          var location = root.locationFromKey(value)
          if (location) root.chooseLocation(location, true)
        }
      }

      OmaSearchableDropdown {
        width: parent.width
        label: "Search exit location"
        placeholderText: "Search country, city, provider, or relay"
        triggerLabel: root.relayTargetLabel()
        options: root.locationOptions()
        value: root.constraintKey((service.relayConstraints || {}).location)
        enabled: !service.busy && root.cliReady
        opacity: root.cliReady ? 1 : 0.35
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(value) {
          var location = root.locationFromKey(value)
          if (location) root.chooseLocation(location, service.active)
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "ACCOUNT"; foreground: root.foreground; fontFamily: root.fontFamily }

      Column {
        visible: !service.loggedIn
        enabled: root.cliReady
        opacity: root.cliReady ? 1 : 0.35
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Your account number is sent to mullvad account login over stdin and is never saved by OmaMullvad."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: accountField
            Layout.fillWidth: true
            password: true
            foreground: root.foreground
            placeholderText: "16-digit account number"
            inputMethodHints: Qt.ImhDigitsOnly | Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
            validator: RegularExpressionValidator { regularExpression: /[0-9 ]{0,19}/ }
            onAccepted: loginButton.clicked()
            Keys.onEscapePressed: {
              text = ""
              keyCatcher.forceActiveFocus()
            }
          }

          Button {
            id: loginButton
            text: "Login"
            bordered: true
            focusable: true
            enabled: service.installed && service.daemonRunning && !service.busy && accountField.text.trim() !== ""
            foreground: root.foreground
            onClicked: {
              var account = accountField.text
              accountField.text = ""
              service.login(account)
              account = ""
            }
          }
        }
      }

      RowLayout {
        visible: service.loggedIn
        width: parent.width
        spacing: Style.space(8)

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "Logged in"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: service.accountExpiry ? "Credit expires " + service.accountExpiry : "Account credit expiry unavailable"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Button {
          text: "Logout"
          focusable: true
          bordered: true
          enabled: !service.busy && root.cliReady
          foreground: root.urgent
          onClicked: root.confirmAction("Log out of the Mullvad account on this device?", function() { service.logout() })
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "CONNECTION POLICY"; foreground: root.foreground; fontFamily: root.fontFamily }

      Toggle {
        width: parent.width
        label: "Lockdown mode"
        description: "Block all network access whenever Mullvad is disconnected"
        checked: service.lockdown
        enabled: !service.busy && root.cliReady
        opacity: root.cliReady ? 1 : 0.35
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: service.setLockdown(!service.lockdown)
      }
      Toggle {
        width: parent.width
        label: "Auto-connect"
        description: "Connect Mullvad when its daemon starts"
        checked: service.autoConnect
        enabled: !service.busy && root.cliReady
        opacity: root.cliReady ? 1 : 0.35
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: service.setAutoConnect(!service.autoConnect)
      }
      Toggle {
        width: parent.width
        label: "Local network sharing"
        description: "Allow access to devices on the local network"
        checked: service.lanSharing
        enabled: !service.busy && root.cliReady
        opacity: root.cliReady ? 1 : 0.35
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: service.setLanSharing(!service.lanSharing)
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Keys: 1–4 pages · T tunnel · R refresh · N/P favourites · H/L pages · J/K scroll"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Component {
    id: locationsPage

    Column {
      id: locationsColumn
      width: pageFlick.width
      spacing: Style.space(12)
      property var filtered: root.filteredLocations()
      property bool filtersExpanded: false
      readonly property bool filtersActive: ((service.relayConstraints || {}).providers || []).length > 0
        || String((service.relayConstraints || {}).ownership || "any") !== "any"
        || String((service.relayConstraints || {}).ipVersion || "any") !== "any"
        || !!(service.relayConstraints || {}).multihop
      Keys.onEscapePressed: root.close()

      PanelHero {
        width: parent.width
        title: "Location controls"
        meta: "Manage favourites and fine-tune relay selection"
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          ThemeIcon { iconSize: Style.font.display; state: "location"; color: root.foreground; urgentColor: root.urgent }
        }
      }

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        TextField {
          id: locationSearch
          Layout.fillWidth: true
          foreground: root.foreground
          placeholderText: "Search country, city, provider, or server"
          text: root.locationQuery
          onTextChanged: root.locationQuery = text
          Keys.onEscapePressed: {
            text = ""
            keyCatcher.forceActiveFocus()
          }
        }

        Button {
          Layout.preferredWidth: Style.space(112)
          text: locationsColumn.filtersExpanded ? "Hide filters" : "Filters"
          selected: locationsColumn.filtersExpanded || locationsColumn.filtersActive
          bordered: true
          focusable: true
          foreground: root.foreground
          onClicked: locationsColumn.filtersExpanded = !locationsColumn.filtersExpanded
        }
      }

      Column {
        visible: locationsColumn.filtersExpanded
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader { text: "RELAY FILTERS"; foreground: root.foreground; fontFamily: root.fontFamily }

        OmaSearchableDropdown {
          width: parent.width
          label: "Providers"
          options: service.providers
          multiple: true
          values: (service.relayConstraints || {}).providers || []
          enabled: !service.busy
          triggerLabel: "Any provider"
          placeholderText: "Search providers"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onSelectionChanged: function(values) { service.setProviders(values) }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          OmaDropdown {
            Layout.fillWidth: true
            label: "Ownership"
            options: [
              { value: "any", label: "Any" },
              { value: "owned", label: "Mullvad-owned" },
              { value: "rented", label: "Rented" }
            ]
            value: String((service.relayConstraints || {}).ownership || "any")
            enabled: !service.busy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { service.setOwnership(value) }
          }
          OmaDropdown {
            Layout.fillWidth: true
            label: "Tunnel IP"
            options: [
              { value: "any", label: "Any" },
              { value: "ipv4", label: "IPv4" },
              { value: "ipv6", label: "IPv6" }
            ]
            value: String((service.relayConstraints || {}).ipVersion || "any")
            enabled: !service.busy
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { service.setIpVersion(value) }
          }
        }

        Toggle {
          width: parent.width
          label: "WireGuard multihop"
          description: "Route through a separate entry relay before the exit relay"
          checked: !!(service.relayConstraints || {}).multihop
          enabled: !service.busy
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: service.setMultihop(!checked)
        }

        OmaSearchableDropdown {
          width: parent.width
          label: "Multihop entry city"
          placeholderText: "Search entry relay"
          options: root.locationOptions()
          value: root.constraintKey((service.relayConstraints || {}).entry)
          enabled: !service.busy
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) {
            var location = root.locationFromKey(value)
            if (location) service.setEntryLocation(location.countryCode, location.cityCode)
          }
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "COUNTRIES & CITIES"; foreground: root.foreground; fontFamily: root.fontFamily }

      Text {
        textFormat: Text.PlainText
        visible: locationsColumn.filtered.length === 0
        width: parent.width
        text: service.locations.length === 0 ? "Loading Mullvad relay locations…" : "No locations match your search."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      ListView {
        id: locationList
        width: parent.width
        height: Math.min(contentHeight, Style.space(240))
        spacing: Style.space(5)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        model: locationsColumn.filtered
        delegate: LocationRow {
          required property var modelData
          required property int index
          width: ListView.view.width
          height: implicitHeight
          location: modelData
          favorite: root.isFavorite(modelData)
          selected: root.selectedLocation && root.locationKey(root.selectedLocation) === root.locationKey(modelData)
          onActiveFocusChanged: if (activeFocus) locationList.positionViewAtIndex(index, ListView.Contain)
          onChosen: root.chooseLocation(location, service.active)
          onFavoriteToggled: root.toggleFavorite(location)
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "SELECTED RELAY"; foreground: root.foreground; fontFamily: root.fontFamily }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.selectedLocation
          ? root.selectedLocation.city + ", " + root.selectedLocation.country
          : "Select a city above to choose a specific server."
        color: root.selectedLocation ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      OmaSearchableDropdown {
        visible: root.selectedLocation !== null
        width: parent.width
        label: "Specific server"
        placeholderText: "Search hostname or provider"
        options: root.serverOptions(root.selectedLocation)
        value: root.selectedServerValue(root.selectedLocation)
        enabled: !service.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(value) {
          var location = root.selectedLocation
          if (location) service.selectLocation(location.countryCode, location.cityCode,
                                                service.active, value)
        }
      }

      Column {
        visible: root.recentLocations.length > 0
        width: parent.width
        spacing: Style.space(6)
        PanelSeparator { foreground: root.foreground }
        PanelSectionHeader { text: "RECENT"; foreground: root.foreground; fontFamily: root.fontFamily }
        Repeater {
          model: root.recentLocations
          SavedLocationRow {
            required property var modelData
            width: parent.width
            location: modelData
            prefix: "󰋚"
            available: root.locationFor(modelData) !== null
            subtitle: available ? "Use this relay" : "Relay no longer available"
            onChosen: if (available) root.chooseLocation(root.locationFor(location), service.active)
          }
        }
      }

    }
  }

  component SavedLocationRow: CursorSurface {
    id: savedRow
    property var location: null
    property string prefix: ""
    property bool available: true
    property string subtitle: ""
    signal chosen()

    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    opacity: available ? 1 : 0.55
    implicitHeight: savedContent.implicitHeight + Style.space(14)
    Keys.onReturnPressed: if (available && !service.busy) chosen()
    Keys.onEnterPressed: if (available && !service.busy) chosen()
    Keys.onSpacePressed: if (available && !service.busy) chosen()

    RowLayout {
      id: savedContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: savedRow.prefix
        color: savedRow.available ? root.foreground : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: savedRow.location ? String(savedRow.location.city || savedRow.location.cityCode) + ", " + String(savedRow.location.country || savedRow.location.countryCode) : "Unknown"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: savedRow.subtitle
          color: savedRow.available ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: savedRow.available && !service.busy
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: savedRow.chosen()
    }
  }

  component LocationRow: CursorSurface {
    id: locationRow
    property var location: null
    property bool favorite: false
    property bool selected: false
    signal chosen()
    signal favoriteToggled()

    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    current: selected
    implicitHeight: locationContent.implicitHeight + Style.space(12)
    Keys.onReturnPressed: if (!service.busy) chosen()
    Keys.onEnterPressed: if (!service.busy) chosen()
    Keys.onSpacePressed: if (!service.busy) chosen()

    RowLayout {
      id: locationContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "󰖂"
        color: locationRow.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: locationRow.location ? String(locationRow.location.city || "Any city") + ", " + String(locationRow.location.country || "") : "Unknown"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: locationRow.selected
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: locationRow.location ? root.locationKey(locationRow.location) + (locationRow.location.servers ? " · " + locationRow.location.servers.length + " relays" : "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
      PanelActionButton {
        iconText: locationRow.favorite ? "󰋑" : "󰋕"
        tooltipText: locationRow.favorite ? "Remove favourite" : (root.favoriteLocations.length >= 9 ? "Nine favourites already saved" : "Add favourite")
        foreground: locationRow.favorite ? root.foreground : root.dim
        enabled: locationRow.favorite || root.favoriteLocations.length < 9
        fontFamily: root.fontFamily
        focusable: true
        onClicked: locationRow.favoriteToggled()
      }
    }

    MouseArea {
      anchors.fill: parent
      anchors.rightMargin: Style.space(42)
      enabled: !service.busy
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: locationRow.chosen()
    }
  }

  Component {
    id: advancedPage

    Column {
      id: advancedColumn
      width: pageFlick.width
      spacing: Style.space(12)
      property string selectedAntiMode: String((service.antiCensorship || {}).mode || "auto")
      Keys.onEscapePressed: root.close()

      PanelHero {
        width: parent.width
        title: "Advanced settings"
        meta: "DNS and anti-censorship"
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          ThemeIcon { iconSize: Style.font.display; state: "advanced"; color: root.foreground; urgentColor: root.urgent }
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "DNS CONTENT BLOCKING"; foreground: root.foreground; fontFamily: root.fontFamily }

      Toggle {
        width: parent.width; label: "Ads"; checked: !!(service.dns || {}).blockAds
        enabled: !service.busy; foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: service.setDnsDefault(root.dnsFlags("blockAds", !checked))
      }
      Toggle {
        width: parent.width; label: "Trackers"; checked: !!(service.dns || {}).blockTrackers
        enabled: !service.busy; foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: service.setDnsDefault(root.dnsFlags("blockTrackers", !checked))
      }
      Toggle {
        width: parent.width; label: "Malware"; checked: !!(service.dns || {}).blockMalware
        enabled: !service.busy; foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: service.setDnsDefault(root.dnsFlags("blockMalware", !checked))
      }
      Toggle {
        width: parent.width; label: "Adult content"; checked: !!(service.dns || {}).blockAdultContent
        enabled: !service.busy; foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: service.setDnsDefault(root.dnsFlags("blockAdultContent", !checked))
      }
      Toggle {
        width: parent.width; label: "Gambling"; checked: !!(service.dns || {}).blockGambling
        enabled: !service.busy; foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: service.setDnsDefault(root.dnsFlags("blockGambling", !checked))
      }
      Toggle {
        width: parent.width; label: "Social media"; checked: !!(service.dns || {}).blockSocialMedia
        enabled: !service.busy; foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: service.setDnsDefault(root.dnsFlags("blockSocialMedia", !checked))
      }

      RowLayout {
        width: parent.width
        spacing: Style.space(8)
        TextField {
          id: dnsField
          Layout.fillWidth: true
          foreground: root.foreground
          placeholderText: "Custom DNS: 1.1.1.1, 2606:4700:4700::1111"
          text: ((service.dns || {}).servers || []).join(", ")
          Keys.onEscapePressed: { keyCatcher.forceActiveFocus() }
        }
        Button {
          text: "Apply"
          bordered: true
          focusable: true
          enabled: dnsField.text.trim() !== "" && !service.busy
          foreground: root.foreground
          onClicked: service.setDnsCustom(dnsField.text.split(/[\s,]+/).filter(function(value) { return value !== "" }))
        }
        Button {
          text: "Default"
          bordered: true
          focusable: true
          enabled: !service.busy
          foreground: root.dim
          onClicked: service.setDnsDefault(root.dnsFlags("", false))
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "ANTI-CENSORSHIP"; foreground: root.foreground; fontFamily: root.fontFamily }

      OmaDropdown {
        id: antiModeDropdown
        width: parent.width
        label: "Mode"
        options: [
          { value: "auto", label: "Automatic" },
          { value: "off", label: "Off" },
          { value: "wireguard-port", label: "WireGuard port" },
          { value: "udp2tcp", label: "UDP-over-TCP" },
          { value: "shadowsocks", label: "Shadowsocks" },
          { value: "quic", label: "QUIC" },
          { value: "lwo", label: "LWO" }
        ]
        value: advancedColumn.selectedAntiMode
        enabled: !service.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(value) {
          service.setAntiCensorshipMode(value)
        }
      }

      RowLayout {
        visible: ["wireguard-port", "udp2tcp", "shadowsocks", "lwo"].indexOf(advancedColumn.selectedAntiMode) !== -1
        width: parent.width
        spacing: Style.space(8)
        NumberField {
          id: antiPortField
          Layout.fillWidth: true
          label: "Port"
          from: 1
          to: 65535
          value: Math.max(1, Number((service.antiCensorship || {}).port) || 443)
          foreground: root.foreground
          fontFamily: root.fontFamily
          onModified: function(value) { antiPortField.value = value }
        }
        Button {
          text: "Set port"
          bordered: true
          focusable: true
          enabled: !service.busy
          foreground: root.foreground
          onClicked: service.setAntiCensorshipPort(advancedColumn.selectedAntiMode, antiPortField.value)
        }
      }
    }
  }

  Component {
    id: excludedPage

    Column {
      id: excludedColumn
      width: pageFlick.width
      spacing: Style.space(12)
      property var apps: root.appRows()
      property var groups: root.excludedGroups()
      Keys.onEscapePressed: root.close()

      PanelHero {
        width: parent.width
        title: "Excluded applications"
        meta: "Launch outside the Mullvad tunnel"
        detail: String(excludedColumn.groups.length)
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          ThemeIcon { iconSize: Style.font.display; state: "excluded"; color: root.foreground; urgentColor: root.urgent }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Apps launched here use mullvad-exclude and remain excluded until their processes exit."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      PanelSectionHeader { text: "RUNNING OUTSIDE VPN"; foreground: root.foreground; fontFamily: root.fontFamily }

      Text {
        textFormat: Text.PlainText
        visible: excludedColumn.groups.length === 0
        width: parent.width
        text: "No excluded processes are currently reported."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        visible: excludedColumn.groups.length > 0
        width: parent.width
        spacing: Style.space(5)
        Repeater {
          model: excludedColumn.groups
          ExcludedGroupRow {
            required property var modelData
            width: parent.width
            group: modelData
          }
        }
      }

      PanelSeparator { foreground: root.foreground }
      PanelSectionHeader { text: "LAUNCH AN APPLICATION"; foreground: root.foreground; fontFamily: root.fontFamily }

      TextField {
        id: appSearch
        width: parent.width
        foreground: root.foreground
        placeholderText: "Search installed applications"
        text: root.appQuery
        onTextChanged: root.appQuery = text
        Keys.onEscapePressed: {
          text = ""
          keyCatcher.forceActiveFocus()
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: excludedColumn.apps.length === 0
        width: parent.width
        text: root.bar && root.bar.shell && root.bar.shell.appLibrary
          ? "No installed applications match your search."
          : "The active bar host does not expose Omarchy’s application library."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }

      Column {
        width: parent.width
        spacing: Style.space(5)
        Repeater {
          model: excludedColumn.apps
          AppRow {
            required property var modelData
            width: parent.width
            app: modelData
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: excludedColumn.apps.length >= 30
        width: parent.width
        text: "Showing the first 30 matches. Refine the search to narrow the list."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  component ExcludedGroupRow: CursorSurface {
    id: groupRow
    property var group: null
    readonly property string labelText: Model.plainText(group && group.label ? group.label : "Excluded process", 128)
    readonly property int procCount: group && group.count ? group.count : 0
    readonly property string rootPidText: String(group && group.rootPid !== undefined ? group.rootPid : "")
    readonly property var pids: (group && group.pids) || []

    foreground: root.foreground
    implicitHeight: groupContent.implicitHeight + Style.space(12)

    RowLayout {
      id: groupContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)
      Text {
        textFormat: Text.PlainText
        text: "󰒃"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: groupRow.labelText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: groupRow.procCount + (groupRow.procCount === 1 ? " process" : " processes") + " · PID " + groupRow.rootPidText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Stop excluding " + groupRow.labelText
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        focusable: true
        enabled: !service.busy && groupRow.pids.length > 0
        onClicked: root.confirmAction("Stop excluding " + groupRow.labelText + " (" + groupRow.procCount + " processes)?", function() {
          service.removeExcludedPids(groupRow.pids)
        })
      }
    }
  }

  component AppRow: CursorSurface {
    id: appRow
    property var app: null
    readonly property var library: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
    readonly property string appName: Model.plainText(library && app ? library.entryName(app) : String(app ? app.name || app.id : "Application"), 128)
    readonly property string appDetail: Model.plainText(library && app ? library.entrySubtext(app) : "", 256)

    foreground: root.foreground
    activeFocusOnTab: true
    hasCursor: activeFocus
    implicitHeight: appContent.implicitHeight + Style.space(12)
    Keys.onReturnPressed: launchExcluded()
    Keys.onEnterPressed: launchExcluded()
    Keys.onSpacePressed: launchExcluded()

    function launchExcluded() {
      if (service.busy || !app || !app.id) return
      service.launchExcludedApp(String(app.id))
      root.close()
    }

    RowLayout {
      id: appContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)
      Image {
        Layout.preferredWidth: Style.space(24)
        Layout.preferredHeight: Style.space(24)
        sourceSize.width: width
        sourceSize.height: height
        source: appRow.library && appRow.app ? appRow.library.iconSource(String(appRow.app.icon || "")) : ""
        fillMode: Image.PreserveAspectFit
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: appRow.appName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          Layout.fillWidth: true
          text: appRow.appDetail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
      Text {
        textFormat: Text.PlainText
        text: "󰍉"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: !service.busy && appRow.app && appRow.app.id
      hoverEnabled: true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: appRow.launchExcluded()
    }
  }
}
