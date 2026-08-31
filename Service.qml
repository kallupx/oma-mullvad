import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property int pollInterval: 30000
  readonly property string commandGuard: String(Qt.resolvedUrl("bounded-command")).replace(/^file:\/\//, "")
  readonly property int finiteOutputLines: 4096
  readonly property int finiteOutputChars: 262144
  readonly property int listenerLineChars: 8192

  property bool installed: false
  property string cliVersion: ""
  readonly property bool cliVersionSupported: Model.isCliVersionSupported(cliVersion)
  property bool daemonRunning: false
  property bool loggedIn: false
  property bool connected: false
  property string disconnectingAction: ""
  readonly property bool transitional: state === "connecting" || state === "disconnecting"
  readonly property bool active: connected || state === "connecting" || state === "error" || state === "blocked"
    || (state === "disconnecting" && disconnectingAction !== "nothing")
  state: "checking"
  property string statusText: "Checking Mullvad…"
  property string country: ""
  property string city: ""
  property string hostname: ""
  property string ip: ""
  property string currentCountryCode: ""
  property string currentCityCode: ""
  property string accountExpiry: ""
  property int accountDaysRemaining: -1
  property bool tunnelDropWarning: false

  property var locations: []
  property var providers: []
  property var relayConstraints: ({
    location: {}, providers: [], ownership: "any", ipVersion: "any",
    multihop: false, entry: {}
  })
  property bool lockdown: false
  property bool autoConnect: false
  property bool lanSharing: false
  property var dns: ({
    mode: "default", servers: [], blockAds: false, blockTrackers: false,
    blockMalware: false, blockAdultContent: false, blockGambling: false,
    blockSocialMedia: false
  })
  property var antiCensorship: ({ mode: "auto", port: "any" })
  property var excludedPids: []

  property string actionStatus: ""
  property string lastError: ""
  property var _readQueue: []
  property string _readKind: ""
  // Per-source sequence captured at start: _applyStatus ignores results older
  // than the last applied, so a slow poll never clobbers a newer listener event.
  property int _statusSeq: 0
  property int _statusApplySeq: 0
  property int _pendingStatusSeq: 0
  property var _readLines: []
  property var _readErrorLines: []
  property int _readOutputLines: 0
  property int _readOutputChars: 0
  property var _actionQueue: []
  property var _actionLines: []
  property var _actionErrorLines: []
  property int _actionOutputLines: 0
  property int _actionOutputChars: 0
  readonly property bool busy: actionProcess.running || _actionQueue.length > 0
    || readProcess.running || _readQueue.length > 0

  function _redact(value) {
    return Model.redact(String(value || ""))
  }

  function _shortError(value, fallback) {
    var text = Model.plainText(value, 181)
    if (!text) text = fallback
    return text.length > 180 ? text.slice(0, 177) + "…" : text
  }

  function _finiteCommand(command, timeoutSeconds) {
    return [commandGuard, "finite", String(timeoutSeconds), String(finiteOutputLines),
            String(finiteOutputChars), "--"].concat(command || [])
  }

  function _listenerCommand(command) {
    return [commandGuard, "listen", String(listenerLineChars), "--"].concat(command || [])
  }

  function _resetReadOutput() {
    _readLines = []
    _readErrorLines = []
    _readOutputLines = 0
    _readOutputChars = 0
  }

  function _appendReadOutput(line, errorStream) {
    if (_readOutputLines >= finiteOutputLines || _readOutputChars >= finiteOutputChars) return
    var value = _redact(line)
    var remaining = finiteOutputChars - _readOutputChars
    if (value.length > remaining) value = value.slice(0, remaining)
    if (errorStream) _readErrorLines.push(value)
    else _readLines.push(value)
    _readOutputLines++
    _readOutputChars += value.length + 1
  }

  function _resetActionOutput() {
    _actionLines = []
    _actionErrorLines = []
    _actionOutputLines = 0
    _actionOutputChars = 0
  }

  function _appendActionOutput(line, errorStream) {
    if (_actionOutputLines >= finiteOutputLines || _actionOutputChars >= finiteOutputChars) return
    var value = _redact(line)
    var remaining = finiteOutputChars - _actionOutputChars
    if (value.length > remaining) value = value.slice(0, remaining)
    if (errorStream) _actionErrorLines.push(value)
    else _actionLines.push(value)
    _actionOutputLines++
    _actionOutputChars += value.length + 1
  }

  function _hasRead(kind) {
    if (readProcess.running && _readKind === kind) return true
    for (var i = 0; i < _readQueue.length; i++)
      if (_readQueue[i].kind === kind) return true
    return false
  }

  function _enqueueRead(kind, command) {
    if (_hasRead(kind)) return
    _readQueue = _readQueue.concat([{ kind: kind, command: command }])
    _startNextRead()
  }

  function _startNextRead() {
    if (readProcess.running || _readQueue.length === 0) return
    var queue = _readQueue.slice(0)
    var request = queue.shift()
    _readQueue = queue
    _readKind = request.kind
    if (request.kind === "status") root._pendingStatusSeq = ++root._statusSeq
    _resetReadOutput()
    readProcess.command = _finiteCommand(request.command, 10)
    readProcess.running = true
  }

  function refreshAll() {
    _enqueueRead("probe", ["/usr/bin/env", "mullvad", "--version"])
  }

  function _enqueueAuthoritativeReads() {
    _enqueueRead("status", ["mullvad", "status", "--json"])
    _enqueueRead("account", ["mullvad", "account", "get"])
    _enqueueRead("relays", ["mullvad", "relay", "list"])
    _enqueueRead("constraints", ["mullvad", "relay", "get"])
    _enqueueRead("lockdown", ["mullvad", "lockdown-mode", "get"])
    _enqueueRead("autoconnect", ["mullvad", "auto-connect", "get"])
    _enqueueRead("lan", ["mullvad", "lan", "get"])
    _enqueueRead("dns", ["mullvad", "dns", "get"])
    _enqueueRead("antiCensorship", ["mullvad", "anti-censorship", "get"])
    _enqueueRead("excludedPids", ["mullvad", "split-tunnel", "list"])
  }

  function refreshStatus() {
    if (installed) _enqueueRead("status", ["mullvad", "status", "--json"])
    else refreshAll()
  }

  function _applyStatus(raw, seq) {
    if (seq !== undefined && seq < root._statusApplySeq) return
    var parsed = Model.parseStatus(raw)
    state = String(parsed.state || "unknown")
    connected = parsed.connected === true
    disconnectingAction = String(parsed.disconnectingAction || "")
    daemonRunning = true
    tunnelDropWarning = !!parsed.error || !!parsed.warning || state === "error"
    var location = parsed.location || {}
    country = String(location.country || "")
    city = String(location.city || "")
    hostname = String(location.hostname || "")
    ip = String(location.ipv4 || location.ipv6 || "")
    if (parsed.lockedDown !== undefined) lockdown = parsed.lockedDown === true
    _updateCurrentCodes()
    if (state === "connected") statusText = "Connected"
    else if (state === "connecting") statusText = "Connecting…"
    else if (state === "disconnecting") statusText = "Disconnecting…"
    else if (state === "disconnected") statusText = "Disconnected"
    else if (state === "error") statusText = "Tunnel error"
    else statusText = state ? state.charAt(0).toUpperCase() + state.slice(1) : "Unknown"
    if (seq !== undefined) root._statusApplySeq = seq
  }

  function _updateCurrentCodes() {
    currentCountryCode = ""
    currentCityCode = ""
    if (!connected) return
    var match = hostname.toLowerCase().match(/^([a-z]{2})-([a-z0-9]{3})(?:-|$)/)
    if (match) {
      currentCountryCode = match[1]
      currentCityCode = match[2]
      return
    }
    for (var i = 0; i < locations.length; i++) {
      var location = locations[i]
      if (String(location.name || "").toLowerCase() === city.toLowerCase()
          && String(location.country || "").toLowerCase() === country.toLowerCase()) {
        currentCountryCode = String(location.countryCode || "")
        currentCityCode = String(location.code || "")
        return
      }
    }
  }

  function _applyRead(kind, raw, error, exitCode) {
    if (kind === "probe") {
      installed = exitCode === 0
      cliVersion = installed ? Model.parseCliVersion(raw) : ""
      if (!installed) {
        daemonRunning = false
        connected = false
        state = "unavailable"
        statusText = "Mullvad is not installed"
        lastError = "Mullvad CLI not found. Install Mullvad VPN, then refresh."
        if (listenerProcess.running) listenerProcess.running = false
      } else {
        if (lastError.indexOf("Mullvad CLI not found") === 0) lastError = ""
        _enqueueAuthoritativeReads()
      }
      return
    }

    var combined = String(raw || "") + "\n" + String(error || "")
    if (kind === "status") {
      if (exitCode !== 0) {
        if (root._pendingStatusSeq < root._statusApplySeq) return
        daemonRunning = false
        connected = false
        state = "unavailable"
        statusText = "Mullvad daemon unavailable"
        var daemonDetail = _shortError(combined, "")
        lastError = "Mullvad daemon unavailable. Open Mullvad VPN or start mullvad-daemon, then refresh."
          + (daemonDetail ? " " + daemonDetail : "")
        return
      }
      try {
        _applyStatus(raw, root._pendingStatusSeq)
        if (lastError.indexOf("Mullvad daemon unavailable") === 0) lastError = ""
        _ensureListener()
      } catch (e) {
        lastError = _shortError(e, "Could not parse Mullvad status")
      }
      return
    }

    if (kind === "account") {
      try {
        var account = Model.parseAccount(combined, Date.now())
        loggedIn = account.loggedIn === true
        accountExpiry = String(account.expiresAt || "")
        accountDaysRemaining = account.daysRemaining === undefined || account.daysRemaining === null
          ? -1 : Number(account.daysRemaining)
      } catch (e) {
        loggedIn = false
        accountExpiry = ""
        accountDaysRemaining = -1
      }
      return
    }
    if (exitCode !== 0) return

    try {
      if (kind === "relays") {
        var relayData = Model.parseRelayList(raw)
        var parsedLocations = relayData.locations || []
        var nextLocations = []
        for (var i = 0; i < parsedLocations.length; i++) {
          var relayLocation = parsedLocations[i] || {}
          nextLocations.push({
            country: String(relayLocation.country || ""),
            countryCode: String(relayLocation.countryCode || ""),
            city: String(relayLocation.city || relayLocation.name || ""),
            cityCode: String(relayLocation.cityCode || relayLocation.code || ""),
            name: String(relayLocation.name || relayLocation.city || ""),
            code: String(relayLocation.code || relayLocation.cityCode || ""),
            key: String(relayLocation.key || ""),
            latitude: Number(relayLocation.latitude),
            longitude: Number(relayLocation.longitude),
            servers: relayLocation.servers || []
          })
        }
        locations = nextLocations
        providers = relayData.providers || []
        _updateCurrentCodes()
      } else if (kind === "constraints") {
        relayConstraints = Model.parseRelayConstraints(raw)
      } else if (kind === "lockdown") {
        var lockdownValue = Model.parseToggle(raw)
        if (lockdownValue !== null) lockdown = lockdownValue === true
      } else if (kind === "autoconnect") {
        var autoValue = Model.parseToggle(raw)
        if (autoValue !== null) autoConnect = autoValue === true
      } else if (kind === "lan") {
        var lanValue = Model.parseToggle(raw)
        if (lanValue !== null) lanSharing = lanValue === true
      } else if (kind === "dns") {
        var dnsValue = Model.parseDns(raw)
        dns = {
          mode: String(dnsValue.mode || "default"),
          servers: dnsValue.customServers || [],
          blockAds: dnsValue.blockAds === true,
          blockTrackers: dnsValue.blockTrackers === true,
          blockMalware: dnsValue.blockMalware === true,
          blockAdultContent: dnsValue.blockAdultContent === true,
          blockGambling: dnsValue.blockGambling === true,
          blockSocialMedia: dnsValue.blockSocialMedia === true
        }
      } else if (kind === "antiCensorship") {
        var anti = Model.parseAntiCensorship(raw)
        var mode = String(anti.mode || "auto")
        var portKey = mode === "wireguard-port" ? "wireguardPort"
          : mode === "shadowsocks" ? "shadowsocksPort"
          : mode === "udp2tcp" ? "udp2tcpPort"
          : mode === "lwo" ? "lwoPort" : ""
        antiCensorship = {
          mode: mode,
          port: portKey ? String(anti[portKey] === undefined ? "any" : anti[portKey]) : "any",
          udp2tcpPort: anti.udp2tcpPort,
          shadowsocksPort: anti.shadowsocksPort,
          wireguardPort: anti.wireguardPort,
          lwoPort: anti.lwoPort
        }
      } else if (kind === "excludedPids") {
        excludedPids = Model.parseExcludedPids(raw)
      }
    } catch (e) {
      lastError = _shortError(e, "Could not parse Mullvad " + kind)
    }
  }

  function _ensureListener() {
    if (!installed || !daemonRunning || listenerProcess.running) return
    listenerRestart.stop()
    listenerProcess.running = true
  }

  function _command(action, params) {
    if (!installed) {
      lastError = "Mullvad CLI not found. Install Mullvad VPN, then refresh."
      return null
    }
    try {
      return Model.argv(action, params || {})
    } catch (e) {
      lastError = _shortError(e, "Invalid Mullvad setting")
      actionStatus = lastError
      return null
    }
  }

  function _enqueueAction(command, label) {
    if (!command || command.length === 0) return false
    _actionQueue = _actionQueue.concat([{ command: command, label: label }])
    _startNextAction()
    return true
  }

  function _runAction(action, params, label) {
    return _enqueueAction(_command(action, params), label)
  }

  function _startNextAction() {
    if (actionProcess.running || _actionQueue.length === 0) return
    var queue = _actionQueue.slice(0)
    var action = queue.shift()
    _actionQueue = queue
    _resetActionOutput()
    actionProcess.label = action.label
    actionProcess.secret = ""
    actionProcess.command = _finiteCommand(action.command, 20)
    actionStatus = action.label + "…"
    actionProcess.running = true
  }

  function connectTunnel() {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return }
    if (!_relayAvailable(_relaySettings())) return
    _runAction("connect", {}, "Connecting")
  }

  function disconnectTunnel() {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return }
    _runAction("disconnect", {}, "Disconnecting")
  }

  function toggleTunnel() {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return }
    if (active) disconnectTunnel()
    else connectTunnel()
  }

  function login(account) {
    var secret = String(account || "").replace(/\s+/g, "")
    if (!/^\d{16}$/.test(secret)) {
      lastError = "Enter a valid 16-digit Mullvad account number."
      actionStatus = lastError
      secret = ""
      return
    }
    if (busy) {
      lastError = "Wait for the current Mullvad action to finish."
      actionStatus = lastError
      secret = ""
      return
    }
    var command = _command("login", {})
    if (!command) {
      secret = ""
      return
    }
    _resetActionOutput()
    actionProcess.label = "Logging in"
    actionProcess.command = _finiteCommand(command, 20)
    actionProcess.secret = secret
    actionStatus = "Logging in…"
    secret = ""
    actionProcess.running = true
  }

  function logout() { _runAction("logout", {}, "Logging out") }

  function _relaySettings(location, field, value) {
    var current = relayConstraints || ({})
    var next = {
      location: location || current.location || ({}),
      providers: current.providers || [],
      ownership: String(current.ownership || "any"),
      ipVersion: String(current.ipVersion || "any"),
      multihop: current.multihop === true,
      entry: current.entry || ({})
    }
    if (field) next[field] = value
    return next
  }

  function _relayAvailable(settings) {
    if (locations.length === 0)
      lastError = "Mullvad relay data is still loading. Refresh and try again."
    else if (Model.relayConstraintAvailable(locations, settings.location, settings))
      return true
    else
      lastError = "No Mullvad relays match that location and the active filters. Choose another location or clear a filter."
    actionStatus = lastError
    return false
  }

  function selectLocation(countryCode, cityCode, shouldConnect, hostname) {
    if (busy) { actionStatus = "Wait for the current Mullvad action to finish."; return false }
    var target = {
      type: hostname ? "hostname" : "city",
      countryCode: String(countryCode || "").toLowerCase(),
      cityCode: String(cityCode || "").toLowerCase(),
      hostname: String(hostname || "")
    }
    var nextSettings = _relaySettings(target)
    if (!_relayAvailable(nextSettings)) return false
    var locationCommand = _command("location", {
      country: countryCode, city: cityCode, hostname: hostname || ""
    })
    if (!locationCommand) return false
    var followup = null
    if (shouldConnect === true)
      followup = _command(active ? "reconnect" : "connect", {})
    _enqueueAction(locationCommand, "Selecting location")
    relayConstraints = nextSettings
    if (followup) _enqueueAction(followup, active ? "Reconnecting" : "Connecting")
    return true
  }

  function setLockdown(enabled) { _runAction("lockdown", { enabled: enabled }, "Updating lockdown") }
  function setAutoConnect(enabled) { _runAction("autoConnect", { enabled: enabled }, "Updating auto-connect") }
  function setLanSharing(enabled) { _runAction("lanSharing", { enabled: enabled }, "Updating LAN sharing") }
  function setProviders(values) {
    var next = _relaySettings(null, "providers", values)
    if (_relayAvailable(next) && _runAction("providers", { providers: values }, "Updating providers"))
      relayConstraints = next
  }
  function setOwnership(value) {
    var next = _relaySettings(null, "ownership", value)
    if (_relayAvailable(next) && _runAction("ownership", { ownership: value }, "Updating ownership"))
      relayConstraints = next
  }
  function setIpVersion(value) {
    var next = _relaySettings(null, "ipVersion", value)
    if (_relayAvailable(next) && _runAction("ipVersion", { ipVersion: value }, "Updating IP version"))
      relayConstraints = next
  }
  function setMultihop(enabled) { _runAction("multihop", { enabled: enabled }, "Updating multihop") }
  function setEntryLocation(countryCode, cityCode) {
    _runAction("entryLocation", { country: countryCode, city: cityCode }, "Updating entry location")
  }
  function setDnsDefault(flags) { _runAction("dnsDefault", { flags: flags || {} }, "Updating DNS") }
  function setDnsCustom(servers) { _runAction("dnsCustom", { servers: servers }, "Updating DNS") }

  function setAntiCensorshipMode(mode) {
    _runAction("antiCensorshipMode", { mode: mode }, "Updating anti-censorship")
  }
  function setAntiCensorshipPort(mode, port) {
    _runAction("antiCensorshipPort", { mode: mode, port: port }, "Updating anti-censorship port")
  }

  function launchExcludedApp(desktopId) {
    var id = String(desktopId || "").trim()
    if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
    var command = _command("launchExcluded", { desktopId: id + ".desktop" })
    if (!command) return
    Quickshell.execDetached(command)
    actionStatus = "Launched outside the VPN"
    actionStatusTimer.restart()
    excludedRefresh.restart()
  }

  function removeExcludedPid(pid) {
    _runAction("excludedPidDelete", { pid: pid }, "Removing excluded process")
  }

  Timer {
    interval: Math.max(5000, Math.min(3600000, root.pollInterval))
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.installed ? root.refreshStatus() : root.refreshAll()
  }

  Timer {
    id: listenerRestart
    interval: 5000
    repeat: false
    onTriggered: root._ensureListener()
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: excludedRefresh
    interval: 1000
    repeat: false
    onTriggered: root._enqueueRead("excludedPids", ["mullvad", "split-tunnel", "list"])
  }

  Process {
    id: readProcess
    command: []
    running: false
    stdout: SplitParser {
      onRead: function(line) { root._appendReadOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendReadOutput(line, true) }
    }
    onExited: function(exitCode) {
      var kind = root._readKind
      var raw = root._readLines.join("\n")
      var error = root._readErrorLines.join("\n")
      root._readKind = ""
      root._applyRead(kind, raw, error, exitCode)
      Qt.callLater(root._startNextRead)
    }
  }

  Process {
    id: listenerProcess
    command: root._listenerCommand(["mullvad", "status", "--json", "listen"])
    running: false
    stdout: SplitParser {
      onRead: function(line) {
        var boundedLine = String(line || "").slice(0, root.listenerLineChars)
        if (!boundedLine.trim() || !Model.isTunnelStateEvent(boundedLine)) return
        try {
          root._applyStatus(boundedLine, ++root._statusSeq)
        } catch (e) {
          root.lastError = root._shortError(e, "Could not parse live Mullvad status")
        }
      }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var boundedLine = String(line || "").slice(0, root.listenerLineChars)
        if (boundedLine.trim()) root.lastError = root._shortError(boundedLine, "Mullvad status listener failed")
      }
    }
    onExited: function() {
      if (root.installed) {
        root.refreshStatus()
        listenerRestart.restart()
      }
    }
  }

  Process {
    id: actionProcess
    property string label: ""
    property string secret: ""
    command: []
    running: false
    stdinEnabled: true
    onStarted: {
      if (secret.length > 0) {
        var value = secret
        secret = ""
        write(value + "\n")
        value = ""
      }
    }
    stdout: SplitParser {
      onRead: function(line) { root._appendActionOutput(line, false) }
    }
    stderr: SplitParser {
      onRead: function(line) { root._appendActionOutput(line, true) }
    }
    onExited: function(exitCode) {
      var output = root._actionLines.join("\n")
      var error = root._actionErrorLines.join("\n")
      if (exitCode !== 0) {
        root.lastError = root._shortError(error || output, label + " failed")
        root.actionStatus = root.lastError
        root._actionQueue = []
      } else {
        root.lastError = ""
        root.actionStatus = label + " complete"
        actionStatusTimer.restart()
      }
      root.refreshAll()
      if (exitCode === 0) Qt.callLater(root._startNextAction)
    }
  }
}
