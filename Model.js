.pragma library

// Pure Mullvad CLI parsing and argv construction. Keep this file usable from
// QML; tests strip the QML pragma and evaluate it in a Node vm context.

var MAX_INPUT_CHARS = 262144;
var MAX_INPUT_LINES = 4096;
var MAX_LINE_CHARS = 8192;
var MAX_FIELD_CHARS = 256;
var MAX_COUNTRIES = 128;
var MAX_LOCATIONS = 512;
var MAX_SERVERS = 2048;
var MAX_SERVERS_PER_LOCATION = 128;
var MAX_PROVIDERS = 128;
var MAX_EXCLUDED_PIDS = 256;
var SUPPORTED_CLI_SERIES = ["2026.4"];

function text(value) {
    return value === undefined || value === null ? "" : String(value);
}

function boundedInput(value, maxChars) {
    return text(value).slice(0, maxChars || MAX_INPUT_CHARS);
}

function boundedLines(value, maxLines, maxChars) {
    var lines = boundedInput(value, maxChars || MAX_INPUT_CHARS).split(/\r?\n/);
    var limit = Math.min(lines.length, maxLines || MAX_INPUT_LINES);
    var result = [];
    for (var i = 0; i < limit; ++i)
        result.push(lines[i].slice(0, MAX_LINE_CHARS));
    return result;
}

function redact(value) {
    return text(value)
        .replace(/\b(?:\d[ -]?){15}\d\b/g, "[redacted-account]")
        .replace(/\b(Bearer)\s+[A-Za-z0-9._~+\/=\-]{8,}/gi, "$1 [redacted]")
        .replace(/\b(token|secret|password|authorization|api[_-]?key)\s*([:=])\s*([^\s,;]+)/gi,
                 "$1$2[redacted]");
}

function plainText(value, maxChars) {
    var limit = Math.max(1, Math.min(Number(maxChars) || MAX_FIELD_CHARS, 4096));
    return redact(text(value).slice(0, limit))
        .replace(/<[^>]*>/g, " ")
        .replace(/[\u0000-\u001f\u007f<>]/g, " ")
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, limit);
}

function parseCliVersion(raw) {
    var match = plainText(raw, 64).match(/^mullvad-cli\s+(\d+\.\d+(?:\.\d+)?)(?:\s|$)/);
    return match ? match[1] : "";
}

function isCliVersionSupported(version) {
    var match = plainText(version, 32).match(/^(\d+\.\d+)(?:\.\d+)?$/);
    return match !== null && SUPPORTED_CLI_SERIES.indexOf(match[1]) !== -1;
}

function parseJsonLines(raw) {
    if (raw && typeof raw === "object")
        return [raw];
    var bounded = boundedInput(raw, MAX_INPUT_CHARS);
    var lines = boundedLines(bounded, 32, MAX_INPUT_CHARS);
    var values = [];
    for (var i = 0; i < lines.length; ++i) {
        try {
            values.push(JSON.parse(lines[i]));
        } catch (_) {}
    }
    if (!values.length) {
        try {
            values.push(JSON.parse(bounded));
        } catch (_) {}
    }
    return values;
}

function statusPayload(value) {
    if (!value || typeof value !== "object")
        return {};
    if (value.tunnel_state)
        return value.tunnel_state;
    if (value.type === "tunnel_state" && value.value)
        return value.value;
    if (value.status && typeof value.status === "object")
        return value.status;
    if (value.value && value.value.state)
        return value.value;
    return value;
}

var TUNNEL_STATES = ["connected", "connecting", "disconnecting", "disconnected", "error", "blocked"];

// `status --json listen` also emits settings, relay-list, device, version,
// access-method and leak events; only a tunnel-state line carries a state.
function isTunnelStateEvent(raw) {
    var values = parseJsonLines(raw);
    if (!values.length) return false;
    var state = text(statusPayload(values[values.length - 1]).state || "").toLowerCase();
    return TUNNEL_STATES.indexOf(state) !== -1;
}

function parseStatus(raw) {
    var values = parseJsonLines(raw);
    var value = statusPayload(values.length ? values[values.length - 1] : {});
    var rawDetails = value.details;
    var details = rawDetails && typeof rawDetails === "object" ? rawDetails : {};
    var location = details.location || value.location || {};
    var state = text(value.state || "unknown").toLowerCase();
    if (TUNNEL_STATES.indexOf(state) === -1)
        state = "unknown";
    var errorValue = details.error || value.error || "";
    var hostname = plainText(location.hostname || details.hostname, 253).toLowerCase();
    var entryHostname = plainText(location.entry_hostname || details.entry_hostname, 253).toLowerCase();
    var ipv4 = plainText(location.ipv4, 45);
    var ipv6 = plainText(location.ipv6, 45);
    var disconnectingAction = state === "disconnecting"
        ? plainText(typeof rawDetails === "string" ? rawDetails : details.action, 32).toLowerCase() : "";
    if (["nothing", "block", "reconnect"].indexOf(disconnectingAction) === -1)
        disconnectingAction = state === "disconnecting" ? "unknown" : "";
    return {
        state: state,
        connected: state === "connected",
        connecting: state === "connecting",
        disconnecting: state === "disconnecting",
        disconnectingAction: disconnectingAction,
        error: plainText(typeof errorValue === "string" ? errorValue : JSON.stringify(errorValue), 512),
        warning: plainText(details.warning || value.warning || "", 256),
        location: {
            country: plainText(location.country, 128),
            city: plainText(location.city, 128),
            ipv4: validateIpv4(ipv4) ? ipv4 : "",
            ipv6: validateIpv6(ipv6) ? ipv6 : "",
            hostname: validateHostname(hostname) ? hostname : "",
            entryHostname: validateHostname(entryHostname) ? entryHostname : "",
            mullvadExitIp: location.mullvad_exit_ip === true
        },
        // `locked_down` exists only in the `disconnected` variant; undefined otherwise.
        lockedDown: typeof details.locked_down === "boolean" ? details.locked_down
            : typeof value.locked_down === "boolean" ? value.locked_down : undefined
    };
}

function parseRelayList(raw) {
    var countries = [];
    var locations = [];
    var providers = [];
    var country = null;
    var city = null;
    var serverCount = 0;
    var lines = boundedLines(raw, MAX_INPUT_LINES, MAX_INPUT_CHARS);
    for (var i = 0; i < lines.length; ++i) {
        var line = lines[i];
        var match = line.match(/^([^\t].*?) \(([a-z]{2})\)\s*$/i);
        if (match) {
            if (countries.length >= MAX_COUNTRIES) {
                country = null;
                city = null;
                continue;
            }
            var countryName = plainText(match[1], 128);
            if (!countryName) continue;
            country = { name: countryName, code: match[2].toLowerCase(), cities: [] };
            countries.push(country);
            city = null;
            continue;
        }
        match = line.match(/^\t([^\t].*?) \(([a-z0-9]{3})\)\s+@\s*([+-]?\d+(?:\.\d+)?)°[NS],\s*([+-]?\d+(?:\.\d+)?)°[EW]/i);
        if (match && country && locations.length < MAX_LOCATIONS) {
            var latitude = Number(match[3]);
            var longitude = Number(match[4]);
            var cityName = plainText(match[1], 128);
            if (!cityName || !isFinite(latitude) || !isFinite(longitude)
                    || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180)
                continue;
            city = {
                name: cityName,
                code: match[2].toLowerCase(),
                key: country.code + "-" + match[2].toLowerCase(),
                country: country.name,
                countryCode: country.code,
                latitude: latitude,
                longitude: longitude,
                servers: []
            };
            country.cities.push(city);
            locations.push(city);
            continue;
        }
        match = line.match(/^\t\t(\S+) \(([^)]*)\) - hosted by (.+) \((rented|Mullvad-owned)\)\s*$/i);
        if (match && city && serverCount < MAX_SERVERS && city.servers.length < MAX_SERVERS_PER_LOCATION) {
            var hostname = plainText(match[1], 253).toLowerCase();
            var provider = plainText(match[3], 128);
            if (!validateHostname(hostname) || !provider) continue;
            var ips = match[2].split(",").map(function(ip) { return ip.trim(); })
                .filter(validateDnsAddress).slice(0, 8);
            if (providers.indexOf(provider) === -1 && providers.length < MAX_PROVIDERS)
                providers.push(provider);
            city.servers.push({
                hostname: hostname,
                ips: ips,
                provider: provider,
                ownership: match[4].toLowerCase() === "rented" ? "rented" : "owned"
            });
            serverCount++;
        }
    }
    return { countries: countries, locations: locations, providers: providers.sort() };
}

function normalizeOwnership(value) {
    var ownership = text(value).trim().toLowerCase();
    if (ownership === "owned" || ownership.indexOf("mullvad-owned") !== -1)
        return "owned";
    if (ownership === "rented" || ownership.indexOf("rented") !== -1)
        return "rented";
    return "any";
}

function filterServers(servers, constraints) {
    constraints = constraints || {};
    var wantedProviders = constraints.providers || [];
    var providerMap = {};
    for (var i = 0; i < wantedProviders.length; ++i)
        providerMap[text(wantedProviders[i]).toLowerCase()] = true;
    var ownership = normalizeOwnership(constraints.ownership);
    var ipVersion = text(constraints.ipVersion || "any").toLowerCase();
    return (servers || []).filter(function(server) {
        if (wantedProviders.length && !providerMap[text(server.provider).toLowerCase()])
            return false;
        if (ownership !== "any" && normalizeOwnership(server.ownership) !== ownership)
            return false;
        if (ipVersion !== "ipv4" && ipVersion !== "ipv6")
            return true;
        var marker = ipVersion === "ipv4" ? "." : ":";
        return (server.ips || []).some(function(ip) { return text(ip).indexOf(marker) !== -1; });
    });
}

function filterLocations(locations, query, favorites, constraints) {
    var list = locations && locations.locations ? locations.locations : (locations || []);
    var needle = text(query).trim().toLowerCase();
    var result = list.filter(function(location) {
        var servers = filterServers(location.servers, constraints);
        if (!servers.length)
            return false;
        if (!needle)
            return true;
        var fields = [location.name, location.code, location.country, location.countryCode];
        for (var i = 0; i < servers.length; ++i)
            fields.push(servers[i].hostname, servers[i].provider);
        return fields.join(" ").toLowerCase().indexOf(needle) !== -1;
    });
    var order = {};
    for (var i = 0; favorites && i < favorites.length; ++i)
        order[locationKey(favorites[i])] = i;
    return result.sort(function(a, b) {
        var left = order[locationKey(a)];
        var right = order[locationKey(b)];
        if (left === undefined)
            return right === undefined ? 0 : 1;
        return right === undefined ? -1 : left - right;
    });
}

function relayConstraintAvailable(locations, constraint, filters) {
    var list = locations && locations.locations ? locations.locations : (locations || []);
    constraint = constraint || {};
    var type = text(constraint.type || "any").toLowerCase();
    if (type === "unknown")
        return true;
    for (var i = 0; i < list.length; ++i) {
        var location = list[i];
        if ((type === "country" || type === "city" || type === "hostname")
                && text(location.countryCode).toLowerCase() !== text(constraint.countryCode).toLowerCase())
            continue;
        if ((type === "city" || type === "hostname")
                && text(location.cityCode || location.code).toLowerCase() !== text(constraint.cityCode).toLowerCase())
            continue;
        var servers = filterServers(location.servers, filters);
        if (type === "hostname") {
            var hostname = text(constraint.hostname).toLowerCase();
            servers = servers.filter(function(server) {
                return text(server.hostname).toLowerCase() === hostname;
            });
        }
        if (servers.length)
            return true;
    }
    return false;
}

function validateLocationCode(value, kind) {
    var pattern = kind === "city" ? /^[a-z0-9]{3}$/i : /^[a-z]{2}$/i;
    return pattern.test(text(value));
}

function validateHostname(value) {
    return /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/i.test(text(value));
}

function normalizeLocation(value) {
    value = value || {};
    if (typeof value === "string") {
        var match = value.match(/^([a-z]{2})[-/:]([a-z0-9]{3})$/i);
        if (!match)
            return null;
        value = { countryCode: match[1], cityCode: match[2] };
    }
    var countryCode = text(value.countryCode || value.country).toLowerCase();
    var cityCode = text(value.cityCode || (value.countryCode ? value.code : value.city)).toLowerCase();
    if (!validateLocationCode(countryCode, "country") || !validateLocationCode(cityCode, "city"))
        return null;
    return {
        countryCode: countryCode,
        cityCode: cityCode,
        country: plainText(value.countryName || (value.countryCode ? value.country : ""), 128),
        city: plainText(value.cityName || (value.cityCode ? value.city : value.name), 128),
        key: countryCode + "-" + cityCode
    };
}

function normalizeFavorites(values) {
    var result = [];
    var seen = {};
    values = Array.isArray(values) ? values : [];
    for (var i = 0; i < values.length && result.length < 9; ++i) {
        var favorite = normalizeLocation(values[i]);
        if (favorite && !seen[favorite.key]) {
            seen[favorite.key] = true;
            result.push(favorite);
        }
    }
    return result;
}

function locationKey(value) {
    var normalized = normalizeLocation(value);
    return normalized ? normalized.key : "";
}

function findFavoriteIndex(favorites, current) {
    var key = locationKey(current);
    for (var i = 0; i < favorites.length; ++i) {
        if (locationKey(favorites[i]) === key)
            return i;
    }
    return -1;
}

function cycleFavorite(values, locations, current, direction) {
    var favorites = normalizeFavorites(values);
    if (!favorites.length)
        return null;
    var available = {};
    var list = locations && locations.locations ? locations.locations : (locations || []);
    for (var i = 0; i < list.length; ++i)
        available[locationKey(list[i])] = true;
    var step = Number(direction) < 0 ? -1 : 1;
    var start = findFavoriteIndex(favorites, current);
    if (start < 0)
        start = step > 0 ? -1 : 0;
    for (var offset = 1; offset <= favorites.length; ++offset) {
        var index = (start + step * offset + favorites.length * 2) % favorites.length;
        if (available[favorites[index].key])
            return { favorite: favorites[index], index: index + 1 };
    }
    return null;
}

function addRecent(values, location) {
    var item = normalizeLocation(location);
    if (!item)
        return normalizeFavorites(values).slice(0, 5);
    var result = [item];
    var existing = normalizeFavorites(values);
    for (var i = 0; i < existing.length && result.length < 5; ++i) {
        if (existing[i].key !== item.key)
            result.push(existing[i]);
    }
    return result;
}

function emptyConstraint() {
    return { type: "any", countryCode: "", cityCode: "", hostname: "" };
}

function parseConstraint(value) {
    var raw = plainText(value, 512);
    var result = emptyConstraint();
    var match;
    if (!raw || /^any$/i.test(raw))
        return result;
    if ((match = raw.match(/^country\s+([a-z]{2})$/i))) {
        result.type = "country";
        result.countryCode = match[1].toLowerCase();
    } else if ((match = raw.match(/^city\s+([a-z0-9]{3})\s*,\s*([a-z]{2})$/i))) {
        result.type = "city";
        result.countryCode = match[2].toLowerCase();
        result.cityCode = match[1].toLowerCase();
    } else if ((match = raw.match(/^city\s+([a-z]{2})\s+([a-z0-9]{3})$/i))) {
        result.type = "city";
        result.countryCode = match[1].toLowerCase();
        result.cityCode = match[2].toLowerCase();
    } else if ((match = raw.match(/^hostname\s+([a-z]{2})\s+([a-z0-9]{3})\s+(\S+)$/i))) {
        if (!validateHostname(match[3])) {
            result.type = "unknown";
            return result;
        }
        result.type = "hostname";
        result.countryCode = match[1].toLowerCase();
        result.cityCode = match[2].toLowerCase();
        result.hostname = match[3].toLowerCase();
    } else if ((match = raw.match(/^hostname\s+(\S+)$/i))) {
        var codes = match[1].match(/^([a-z]{2})-([a-z0-9]{3})(?:-|$)/i);
        if (!validateHostname(match[1])) {
            result.type = "unknown";
            return result;
        }
        result.type = "hostname";
        result.countryCode = codes ? codes[1].toLowerCase() : "";
        result.cityCode = codes ? codes[2].toLowerCase() : "";
        result.hostname = match[1].toLowerCase();
    } else result.type = "unknown";
    return result;
}

function parseRelayConstraints(raw) {
    var result = {
        location: emptyConstraint(),
        providers: [],
        ownership: "any",
        ipVersion: "any",
        multihop: false,
        entry: emptyConstraint()
    };
    var lines = boundedLines(raw, 128, 32768);
    for (var i = 0; i < lines.length; ++i) {
        var match = lines[i].match(/^\s*([^:]+):\s*(.*?)\s*$/);
        if (!match)
            continue;
        var key = match[1].trim().toLowerCase();
        var value = plainText(match[2], 512);
        if (key === "location")
            result.location = parseConstraint(value);
        else if (key === "provider(s)" && value.toLowerCase() !== "any")
            result.providers = value.split(/\s*,\s*/).map(function(provider) {
                return plainText(provider, 128);
            }).filter(Boolean).slice(0, 64);
        else if (key === "ownership")
            result.ownership = normalizeOwnership(value);
        else if (key === "ip protocol" && ["any", "ipv4", "ipv6"].indexOf(value.toLowerCase()) !== -1)
            result.ipVersion = value.toLowerCase();
        else if (key === "multihop state")
            result.multihop = /^(enabled|on|true)$/i.test(value);
        else if (key === "multihop entry")
            result.entry = parseConstraint(value);
    }
    return result;
}

function parseAccount(raw, nowMs) {
    var safe = redact(boundedInput(raw, 32768));
    if (/not logged in|no account|logged out/i.test(safe))
        return { loggedIn: false, expiresAt: "", expiryMs: 0, daysRemaining: null, deviceName: "" };
    var expiry = safe.match(/^\s*Expires at:\s*(.+?)\s*$/im);
    var device = safe.match(/^\s*Device name:\s*(.+?)\s*$/im);
    var expiryText = expiry ? plainText(expiry[1], 128) : "";
    var iso = expiryText.replace(/^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s*([+-]\d{2}:\d{2})$/, "$1T$2$3");
    var expiryMs = expiryText ? Date.parse(iso) : NaN;
    var loggedIn = !!(expiry || device || /Mullvad account:/i.test(safe));
    return {
        loggedIn: loggedIn,
        expiresAt: expiryText,
        expiryMs: isNaN(expiryMs) ? 0 : expiryMs,
        daysRemaining: isNaN(expiryMs) ? null : Math.ceil((expiryMs - (nowMs === undefined ? Date.now() : nowMs)) / 86400000),
        deviceName: device ? plainText(device[1], 128) : ""
    };
}

function parseToggle(raw) {
    // Anchor to the first "key:" line so a trailing CLI hint cannot flip the result.
    var input = boundedInput(raw, 4096);
    var lineMatch = input.match(/^[^:\n]*:\s*(on|off|enabled|disabled|allow|block|true|false|yes|no)\b/im);
    if (lineMatch)
        return /^(on|enabled|allow|true|yes)$/i.test(lineMatch[1]);
    var matches = input.toLowerCase().match(/\b(on|off|enabled|disabled|allow|block|true|false|yes|no)\b/g);
    if (!matches || !matches.length)
        return null;
    return /^(on|enabled|allow|true|yes)$/.test(matches[matches.length - 1]);
}

function parseDns(raw) {
    var result = {
        mode: "default",
        customServers: [],
        blockAds: false,
        blockTrackers: false,
        blockMalware: false,
        blockAdultContent: false,
        blockGambling: false,
        blockSocialMedia: false
    };
    var map = {
        "block ads": "blockAds",
        "block trackers": "blockTrackers",
        "block malware": "blockMalware",
        "block adult content": "blockAdultContent",
        "block gambling": "blockGambling",
        "block social media": "blockSocialMedia"
    };
    var lines = boundedLines(raw, 128, 32768);
    for (var i = 0; i < lines.length; ++i) {
        var match = lines[i].match(/^\s*([^:]+):\s*(.*?)\s*$/);
        if (!match)
            continue;
        var key = match[1].trim().toLowerCase();
        var value = plainText(match[2], 1024);
        if (key === "custom dns") {
            result.mode = /^no|off|false$/i.test(value) ? "default" : "custom";
            if (!/^yes|on|true|no|off|false$/i.test(value))
                result.customServers = value.split(/[\s,]+/).filter(validateDnsAddress).slice(0, 16);
        } else if (key === "servers" || key === "custom dns servers") {
            result.customServers = value.split(/[\s,]+/).filter(validateDnsAddress).slice(0, 16);
            if (result.customServers.length)
                result.mode = "custom";
        } else if (map[key]) {
            result[map[key]] = parseToggle(value) === true;
        }
    }
    return result;
}

function parseAntiCensorship(raw) {
    var result = { mode: "auto", udp2tcpPort: "any", shadowsocksPort: "any", wireguardPort: "any", lwoPort: "any" };
    var keys = { "udp2tcp": "udp2tcpPort", "shadowsocks": "shadowsocksPort", "wireguard-port": "wireguardPort", "lwo": "lwoPort" };
    var lines = boundedLines(raw, 128, 32768);
    for (var i = 0; i < lines.length; ++i) {
        var mode = lines[i].match(/^\s*mode:\s*(\S+)/i);
        if (mode) {
            var parsedMode = mode[1].toLowerCase();
            if (["auto", "off", "wireguard-port", "udp2tcp", "shadowsocks", "quic", "lwo"].indexOf(parsedMode) !== -1)
                result.mode = parsedMode;
            continue;
        }
        var setting = lines[i].match(/^\s*(udp2tcp|shadowsocks|wireguard-port|lwo) settings:\s*(?:any port|port\s+)?(\d+|any)?/i);
        if (setting) {
            var port = setting[2] || "any";
            result[keys[setting[1].toLowerCase()]] = port === "any" || validatePort(port) ? port : "any";
        }
    }
    return result;
}

function parseExcludedPids(raw) {
    var result = [];
    var lines = boundedLines(raw, MAX_INPUT_LINES, MAX_INPUT_CHARS);
    for (var i = 0; i < lines.length && result.length < MAX_EXCLUDED_PIDS; ++i) {
        var line = lines[i];
        var match = line.match(/^\s*(\d+)\s*(?::|\s)\s*(.*?)\s*$/);
        // The CLI prints bare PIDs, one per line, with no command text.
        var bare = !match && line.match(/^\s*(\d+)\s*$/);
        var pid = match ? Number(match[1]) : bare ? Number(bare[1]) : 0;
        if ((match || bare) && pid >= 1 && pid <= 2147483647)
            result.push({ pid: pid, command: match ? plainText(match[2], 512) : "" });
    }
    return result;
}

function validatePort(value) {
    if (!/^\d+$/.test(text(value)))
        return false;
    var port = Number(value);
    return port >= 1 && port <= 65535 && Math.floor(port) === port;
}

function validateFavoriteIndex(value) {
    return /^\d+$/.test(text(value)) && Number(value) >= 1 && Number(value) <= 9;
}

function validateIpv4(value) {
    var parts = text(value).split(".");
    if (parts.length !== 4)
        return false;
    for (var i = 0; i < parts.length; ++i) {
        if (!/^\d{1,3}$/.test(parts[i]) || Number(parts[i]) > 255)
            return false;
    }
    return true;
}

function validateIpv6(value) {
    var address = text(value).toLowerCase();
    if (!address || !/^[0-9a-f:.]+$/.test(address) || address.split("::").length > 2)
        return false;
    if (address.indexOf(".") !== -1) {
        var colon = address.lastIndexOf(":");
        if (colon < 0 || !validateIpv4(address.slice(colon + 1)))
            return false;
        address = address.slice(0, colon + 1) + "0:0";
    }
    var compressed = address.indexOf("::") !== -1;
    var halves = address.split("::");
    var parts = [];
    for (var h = 0; h < halves.length; ++h) {
        if (halves[h])
            parts = parts.concat(halves[h].split(":"));
    }
    for (var i = 0; i < parts.length; ++i) {
        if (!/^[0-9a-f]{1,4}$/.test(parts[i]))
            return false;
    }
    return compressed ? parts.length < 8 : parts.length === 8;
}

function validateDnsAddress(value) {
    return validateIpv4(value) || validateIpv6(value);
}

function safeArg(value, label) {
    var result = text(value);
    // A leading "-" would be read as a flag by the receiving binary.
    if (!result || result.length > 512 || /[\x00\r\n]/.test(result) || /^-/.test(result))
        throw new Error("Invalid " + label);
    return result;
}

function choice(value, allowed, label) {
    value = text(value).toLowerCase();
    if (allowed.indexOf(value) === -1)
        throw new Error("Invalid " + label);
    return value;
}

function boolWord(value, yes, no) {
    if (value !== true && value !== false)
        throw new Error("Expected a boolean");
    return value ? yes : no;
}

function locationArgs(params) {
    params = params || {};
    var country = text(params.country || params.countryCode).toLowerCase();
    var city = text(params.city || params.cityCode).toLowerCase();
    var hostname = text(params.hostname);
    if (!validateLocationCode(country, "country"))
        throw new Error("Invalid country code");
    var result = [country];
    if (city) {
        if (!validateLocationCode(city, "city"))
            throw new Error("Invalid city code");
        result.push(city);
    }
    if (hostname) {
        if (!city || !validateHostname(hostname))
            throw new Error("Invalid relay hostname");
        result.push(hostname);
    }
    return result;
}

var dnsFlagMap = {
    blockAds: "--block-ads",
    blockTrackers: "--block-trackers",
    blockMalware: "--block-malware",
    blockAdultContent: "--block-adult-content",
    blockGambling: "--block-gambling",
    blockSocialMedia: "--block-social-media"
};

function dnsDefaultArgs(flags) {
    var result = ["mullvad", "dns", "set", "default"];
    flags = flags || {};
    if (Array.isArray(flags)) {
        for (var i = 0; i < flags.length; ++i) {
            if (!dnsFlagMap[flags[i]])
                throw new Error("Invalid DNS content category");
            result.push(dnsFlagMap[flags[i]]);
        }
    } else {
        Object.keys(dnsFlagMap).forEach(function(key) {
            if (flags[key] === true)
                result.push(dnsFlagMap[key]);
        });
    }
    return result;
}

function dnsCustomArgs(servers) {
    if (typeof servers === "string")
        servers = servers.split(/[\s,]+/).filter(Boolean);
    if (!Array.isArray(servers) || !servers.length || servers.length > 16 || !servers.every(validateDnsAddress))
        throw new Error("Invalid custom DNS server");
    return ["mullvad", "dns", "set", "custom"].concat(servers);
}

function pidArg(value) {
    var pid = Number(value);
    if (!/^\d+$/.test(text(value)) || pid < 1 || pid > 2147483647)
        throw new Error("Invalid PID");
    return String(pid);
}

function argv(action, params) {
    params = params || {};
    switch (action) {
    case "version": return ["mullvad", "--version"];
    case "status": return ["mullvad", "status", "--json"].concat(params.listen ? ["listen"] : []);
    case "relayList": return ["mullvad", "relay", "list"];
    case "relayGet": return ["mullvad", "relay", "get"];
    case "accountGet": return ["mullvad", "account", "get"];
    case "lockdownGet": return ["mullvad", "lockdown-mode", "get"];
    case "autoConnectGet": return ["mullvad", "auto-connect", "get"];
    case "lanSharingGet": return ["mullvad", "lan", "get"];
    case "dnsGet": return ["mullvad", "dns", "get"];
    case "antiCensorshipGet": return ["mullvad", "anti-censorship", "get"];
    case "excludedPidList": return ["mullvad", "split-tunnel", "list"];
    case "connect": return ["mullvad", "connect"];
    case "disconnect": return ["mullvad", "disconnect"];
    case "reconnect": return ["mullvad", "reconnect"];
    case "login":
        if (params.account || params.accountNumber)
            throw new Error("Account numbers must be sent over stdin");
        return ["mullvad", "account", "login"];
    case "logout": return ["mullvad", "account", "logout"];
    case "location": return ["mullvad", "relay", "set", "location"].concat(locationArgs(params));
    case "providers": {
        var providers = params.providers || [];
        if (!Array.isArray(providers) || providers.length > 64)
            throw new Error("Invalid providers");
        providers = providers.length ? providers.map(function(value) { return safeArg(value, "provider"); }) : ["any"];
        return ["mullvad", "relay", "set", "provider"].concat(providers);
    }
    case "ownership": return ["mullvad", "relay", "set", "ownership", choice(params.ownership, ["any", "owned", "rented"], "ownership")];
    case "ipVersion": return ["mullvad", "relay", "set", "ip-version", choice(params.ipVersion, ["any", "ipv4", "ipv6"], "IP version")];
    case "multihop": return ["mullvad", "relay", "set", "multihop", boolWord(params.enabled, "on", "off")];
    case "entryLocation": return ["mullvad", "relay", "set", "entry", "location"].concat(locationArgs(params));
    case "lockdown": return ["mullvad", "lockdown-mode", "set", boolWord(params.enabled, "on", "off")];
    case "autoConnect": return ["mullvad", "auto-connect", "set", boolWord(params.enabled, "on", "off")];
    case "lanSharing": return ["mullvad", "lan", "set", boolWord(params.enabled, "allow", "block")];
    case "dnsDefault": return dnsDefaultArgs(params.flags);
    case "dnsCustom": return dnsCustomArgs(params.servers);
    case "antiCensorshipMode": return ["mullvad", "anti-censorship", "set", "mode", choice(params.mode, ["auto", "off", "wireguard-port", "udp2tcp", "shadowsocks", "quic", "lwo"], "anti-censorship mode")];
    case "antiCensorshipPort": {
        var method = choice(params.mode, ["wireguard-port", "udp2tcp", "shadowsocks", "lwo"], "anti-censorship method");
        var port = text(params.port).toLowerCase();
        if (port !== "any" && !validatePort(port))
            throw new Error("Invalid anti-censorship port");
        return ["mullvad", "anti-censorship", "set", method, "--port", port];
    }
    case "excludedPidDelete": return ["mullvad", "split-tunnel", "delete", pidArg(params.pid)];
    case "launchExcluded": {
        var desktopId = safeArg(params.desktopId, "desktop application ID");
        if (!/^[a-z0-9_.+\-]+(?:\.desktop)?$/i.test(desktopId))
            throw new Error("Invalid desktop application ID");
        return ["mullvad-exclude", "uwsm-app", "--", "gtk-launch", desktopId];
    }
    default: throw new Error("Unknown Mullvad action: " + action);
    }
}

var api = {
    redact: redact,
    plainText: plainText,
    SUPPORTED_CLI_SERIES: SUPPORTED_CLI_SERIES,
    parseCliVersion: parseCliVersion,
    isCliVersionSupported: isCliVersionSupported,
    parseStatus: parseStatus,
    isTunnelStateEvent: isTunnelStateEvent,
    parseRelayList: parseRelayList,
    filterServers: filterServers,
    filterLocations: filterLocations,
    relayConstraintAvailable: relayConstraintAvailable,
    normalizeLocation: normalizeLocation,
    normalizeFavorites: normalizeFavorites,
    findFavoriteIndex: findFavoriteIndex,
    cycleFavorite: cycleFavorite,
    addRecent: addRecent,
    parseRelayConstraints: parseRelayConstraints,
    parseAccount: parseAccount,
    parseToggle: parseToggle,
    parseDns: parseDns,
    parseAntiCensorship: parseAntiCensorship,
    parseExcludedPids: parseExcludedPids,
    validatePort: validatePort,
    validateFavoriteIndex: validateFavoriteIndex,
    validateDnsAddress: validateDnsAddress,
    validateLocationCode: validateLocationCode,
    argv: argv
};

if (typeof module !== "undefined" && module.exports)
    module.exports = api;
