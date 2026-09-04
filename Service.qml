import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property int pollInterval: 30000
  readonly property int finiteOutputLines: 4096
  readonly property int finiteOutputChars: 262144
  readonly property int listenerLineChars: 8192
  property int readTimeoutMs: 10000
  property int actionTimeoutMs: 20000

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
  property string _readOutputRemainder: ""
  property string _readErrorRemainder: ""
  property int _readOutputLines: 0
  property int _readOutputChars: 0
  property var _actionQueue: []
  property var _actionLines: []
  property var _actionErrorLines: []
  property string _actionOutputRemainder: ""
  property string _actionErrorRemainder: ""
  property int _actionOutputLines: 0
  property int _actionOutputChars: 0
  readonly property bool busy: actionProcess.running || _actionQueue.length > 0
    || readProcess.running || _readQueue.length > 0
  property bool _readWatchdogFired: false
  property bool _actionWatchdogFired: false
  property bool _readOverflowed: false
  property bool _actionOverflowed: false
  property bool _listenerOverflowed: false
  property int _readWatchdogFiredCount: 0
  property int _actionWatchdogFiredCount: 0
  property int _readOverflowCount: 0
  property int _actionOverflowCount: 0
  property int _listenerOverflowCount: 0
  property int _readArmedPid: 0
  property int _actionArmedPid: 0
  property int _readGen: 0
  property int _readExitedGen: -1
  property int _actionGen: 0
  property int _actionExitedGen: -1

  function _redact(value) {
    return Model.redact(String(value || ""))
  }

  function _shortError(value, fallback) {
    var text = Model.plainText(value, 181)
    if (!text) text = fallback
    return text.length > 180 ? text.slice(0, 177) + "…" : text
  }

  function _processForKind(kind) {
    return kind === "read" ? readProcess : actionProcess
  }

  function _resetOutput(kind) {
    root["_" + kind + "Lines"] = []
    root["_" + kind + "ErrorLines"] = []
    root["_" + kind + "OutputLines"] = 0
    root["_" + kind + "OutputChars"] = 0
    root["_" + kind + "OutputRemainder"] = ""
    root["_" + kind + "ErrorRemainder"] = ""
    root["_" + kind + "Overflowed"] = false
  }

  function _appendOutputChunk(kind, chunk, errorStream) {
    if (root["_" + kind + "Overflowed"]) return
    var remainderKey = "_" + kind + (errorStream ? "ErrorRemainder" : "OutputRemainder")
    var value = String(root[remainderKey] || "") + String(chunk || "")
    var newline = value.indexOf("\n")
    while (newline >= 0 && !root["_" + kind + "Overflowed"]) {
      var line = value.slice(0, newline)
      if (line.slice(-1) === "\r") line = line.slice(0, -1)
      _appendOutput(kind, line, errorStream)
      value = value.slice(newline + 1)
      newline = value.indexOf("\n")
    }
    root[remainderKey] = value
    var outputKey = "_" + kind + "OutputRemainder"
    var errorKey = "_" + kind + "ErrorRemainder"
    var pendingChars = root[outputKey].length + root[errorKey].length
    var remaining = finiteOutputChars - root["_" + kind + "OutputChars"]
    if (!root["_" + kind + "Overflowed"] && pendingChars >= remaining)
      _flushOutputRemainders(kind)
  }

  function _flushOutputRemainders(kind) {
    var output = root["_" + kind + "OutputRemainder"]
    var error = root["_" + kind + "ErrorRemainder"]
    root["_" + kind + "OutputRemainder"] = ""
    root["_" + kind + "ErrorRemainder"] = ""
    if (output) _appendOutput(kind, output, false)
    if (error) _appendOutput(kind, error, true)
  }

  function _appendOutput(kind, line, errorStream) {
    if (root["_" + kind + "Overflowed"]) return
    var linesKey = "_" + kind + "OutputLines"
    var charsKey = "_" + kind + "OutputChars"
    var atLimit = root[linesKey] >= finiteOutputLines || root[charsKey] >= finiteOutputChars
    var value = _redact(line)
    if (!atLimit) {
      var remaining = finiteOutputChars - root[charsKey]
      if (value.length >= remaining) { value = value.slice(0, remaining); atLimit = true }
      var outputKey = errorStream ? "_" + kind + "ErrorLines" : "_" + kind + "Lines"
      root[outputKey] = root[outputKey].concat([value])
      root[linesKey]++
      root[charsKey] += value.length
      if (root[linesKey] >= finiteOutputLines) atLimit = true
    }
    if (atLimit) {
      root["_" + kind + "Overflowed"] = true
      root["_" + kind + "OverflowCount"]++
      var process = _processForKind(kind)
      if (process.running) process.signal(15)
    }
  }

  function _resetReadOutput() { _resetOutput("read") }
  function _appendReadOutput(line, errorStream) { _appendOutput("read", line, errorStream) }
  function _resetActionOutput() { _resetOutput("action") }
  function _appendActionOutput(line, errorStream) { _appendOutput("action", line, errorStream) }

  function _hasRead(kind) {
    if (readProcess.running && _readKind === kind) return true
    for (var i = 0; i < _readQueue.length; i++)
      if (_readQueue[i].kind === kind) return true
    return false
  }

  function _enqueueRead(kind, command, timeoutMs) {
    if (_hasRead(kind)) return
    _readQueue = _readQueue.concat([{ kind: kind, command: command, timeoutMs: timeoutMs || 0 }])
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
    _readGen++
    readWatchdog.interval = request.timeoutMs || root.readTimeoutMs
    readWatchdog.restart()
    readProcess.command = request.command
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
        lastError = String(error || "").indexOf("timed out") !== -1
          ? "Mullvad CLI check timed out."
          : "Mullvad CLI not found. Install Mullvad VPN, then refresh."
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

  function _armAction(command, label, secret) {
    actionStatusTimer.stop()
    _resetActionOutput()
    _actionGen++
    actionWatchdog.interval = root.actionTimeoutMs
    actionWatchdog.restart()
    actionProcess.stdinEnabled = true
    actionProcess.label = label
    actionProcess.secret = secret || ""
    actionProcess.command = command
    actionStatus = label + "…"
    actionProcess.running = true
  }

  function _startNextAction() {
    if (actionProcess.running || _actionQueue.length === 0) return
    var queue = _actionQueue.slice(0)
    var action = queue.shift()
    _actionQueue = queue
    _armAction(action.command, action.label, "")
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
    _armAction(command, "Logging in", secret)
    secret = ""
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

  Timer {
    id: readWatchdog
    repeat: false
    onTriggered: {
      if (!readProcess.running) return
      root._readWatchdogFired = true
      root._readWatchdogFiredCount++
      readProcess.signal(15)
      readKillTimer.restart()
    }
  }

  Timer {
    id: readKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (readProcess.running && readProcess.processId === root._readArmedPid)
        readProcess.signal(9)
    }
  }

  function _finalizeRead(exitCode, exitStatus, startError) {
    readWatchdog.stop()
    readKillTimer.stop()
    var kind = root._readKind
    _flushOutputRemainders("read")
    root._readKind = ""
    if (startError) root._applyRead(kind, "", startError, exitCode)
    else if (root._readWatchdogFired) {
      root._readWatchdogFired = false
      root._applyRead(kind, "", "timed out", 124)
    } else if (root._readOverflowed)
      root._applyRead(kind, "", "output limit exceeded", 137)
    else {
      var effectiveCode = exitStatus === 1 && exitCode === 0 ? 1 : exitCode
      root._applyRead(kind, root._readLines.join("\n"), root._readErrorLines.join("\n"), effectiveCode)
    }
    Qt.callLater(root._startNextRead)
  }

  Process {
    id: readProcess
    command: []
    running: false
    onStarted: root._readArmedPid = processId
    onRunningChanged: {
      if (!running && root._readGen > 0 && root._readKind !== "") {
        var generation = root._readGen
        Qt.callLater(function() {
          if (root._readGen === generation && root._readExitedGen !== generation) {
            root._readExitedGen = generation
            root._finalizeRead(127, 0, "failed to start")
          }
        })
      }
    }
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._appendOutputChunk("read", chunk, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._appendOutputChunk("read", chunk, true) }
    }
    onExited: function(exitCode, exitStatus) {
      root._readExitedGen = root._readGen
      root._finalizeRead(exitCode, exitStatus, "")
    }
  }

  Process {
    id: listenerProcess
    command: ["mullvad", "status", "--json", "listen"]
    running: false
    property string outputRemainder: ""
    property string errorRemainder: ""
    onStarted: {
      outputRemainder = ""
      errorRemainder = ""
      root._listenerOverflowed = false
    }
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._appendListenerChunk(chunk, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._appendListenerChunk(chunk, true) }
    }
    onExited: function() {
      if (root.installed) {
        root.refreshStatus()
        listenerRestart.restart()
      }
    }
  }

  function _appendListenerChunk(chunk, errorStream) {
    if (_listenerOverflowed) return
    var key = errorStream ? "errorRemainder" : "outputRemainder"
    var value = String(listenerProcess[key] || "") + String(chunk || "")
    var newline = value.indexOf("\n")
    while (newline >= 0) {
      var line = value.slice(0, newline)
      if (line.slice(-1) === "\r") line = line.slice(0, -1)
      if (line.length > listenerLineChars) {
        _overflowListener()
        return
      }
      _applyListenerLine(line, errorStream)
      value = value.slice(newline + 1)
      newline = value.indexOf("\n")
    }
    if (value.length > listenerLineChars) {
      _overflowListener()
      return
    }
    listenerProcess[key] = value
  }

  function _overflowListener() {
    _listenerOverflowed = true
    _listenerOverflowCount++
    listenerProcess.outputRemainder = ""
    listenerProcess.errorRemainder = ""
    lastError = "Mullvad status listener output limit exceeded"
    if (listenerProcess.running) listenerProcess.signal(15)
  }

  function _applyListenerLine(line, errorStream) {
    if (!line.trim()) return
    if (errorStream) {
      lastError = _shortError(line, "Mullvad status listener failed")
      return
    }
    if (!Model.isTunnelStateEvent(line)) return
    try {
      _applyStatus(line, ++_statusSeq)
    } catch (e) {
      lastError = _shortError(e, "Could not parse live Mullvad status")
    }
  }

  Timer {
    id: actionWatchdog
    repeat: false
    onTriggered: {
      if (!actionProcess.running) return
      root._actionWatchdogFired = true
      root._actionWatchdogFiredCount++
      actionProcess.signal(15)
      actionKillTimer.restart()
    }
  }

  Timer {
    id: actionKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (actionProcess.running && actionProcess.processId === root._actionArmedPid)
        actionProcess.signal(9)
    }
  }

  function _finalizeAction(exitCode, exitStatus, startError) {
    actionWatchdog.stop()
    actionKillTimer.stop()
    actionProcess.secret = ""
    _flushOutputRemainders("action")
    var label = actionProcess.label
    var success = false
    if (startError) {
      root.lastError = root._shortError(startError, label + " failed")
      root.actionStatus = root.lastError
      root._actionQueue = []
    } else if (root._actionWatchdogFired) {
      root._actionWatchdogFired = false
      root.lastError = label + " timed out"
      root.actionStatus = root.lastError
      root._actionQueue = []
    } else if (root._actionOverflowed) {
      root.lastError = label + " failed: output limit exceeded"
      root.actionStatus = root.lastError
      root._actionQueue = []
    } else {
      var effectiveCode = exitStatus === 1 && exitCode === 0 ? 1 : exitCode
      var output = root._actionLines.join("\n")
      var error = root._actionErrorLines.join("\n")
      if (effectiveCode !== 0) {
        root.lastError = root._shortError(error || output, label + " failed")
        root.actionStatus = root.lastError
        root._actionQueue = []
      } else {
        root.lastError = ""
        root.actionStatus = label + " complete"
        actionStatusTimer.restart()
        success = true
      }
    }
    root.refreshAll()
    if (success) Qt.callLater(root._startNextAction)
  }

  Process {
    id: actionProcess
    property string label: ""
    property string secret: ""
    command: []
    running: false
    stdinEnabled: true
    onStarted: {
      root._actionArmedPid = processId
      if (secret.length > 0) {
        var value = secret
        secret = ""
        write(value + "\n")
        value = ""
      }
      stdinEnabled = false
    }
    onRunningChanged: {
      if (!running && root._actionGen > 0 && actionProcess.label !== "") {
        secret = ""
        var generation = root._actionGen
        Qt.callLater(function() {
          if (root._actionGen === generation && root._actionExitedGen !== generation) {
            root._actionExitedGen = generation
            root._finalizeAction(127, 0, "failed to start")
          }
        })
      }
    }
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._appendOutputChunk("action", chunk, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._appendOutputChunk("action", chunk, true) }
    }
    onExited: function(exitCode, exitStatus) {
      root._actionExitedGen = root._actionGen
      root._finalizeAction(exitCode, exitStatus, "")
    }
  }
}
