.pragma library

// Every request is a subcommand of bin/miniflux-api, which holds the shell
// side: where credentials live, how curl is called, the size cap and the exit
// codes (10-13 setup, 20 request failed, 21 credentials rejected, 22 response
// too large, 23 API key could not be minted, 24 unsafe store, 64 bad
// arguments). The builders below only assemble argument arrays, so no value
// from QML is ever parsed as shell code.
//
// The script is run by /usr/bin/bash with a scrubbed environment (see
// environment below) rather than executed directly, so it works without the
// executable bit and no bash found on the session's PATH can stand in.
// Nothing inherited from the shell's session can steer it: BASH_ENV would be
// sourced before the script, an exported function could stand in for curl,
// and CURL_HOME or a user PATH entry could swap in a different config or
// binary. The script pins PATH itself too, in case a host ignores
// clearEnvironment.
var bash = "/usr/bin/bash"

// The only variables a command sees. null means "pass through the value from
// the shell's environment, if it has one" (Quickshell's clearEnvironment
// semantics). HOME and XDG_CONFIG_HOME locate the store, the MINIFLUX_ ones
// are the documented overrides, the proxy and CA variables keep a private
// network or a self-signed instance reachable, and PATH is fixed.
var environment = {
  PATH: "/usr/bin:/bin",
  HOME: null,
  XDG_CONFIG_HOME: null,
  MINIFLUX_PLUGIN_DIR: null,
  MINIFLUX_SERVER: null,
  MINIFLUX_USERNAME: null,
  MINIFLUX_API_KEY: null,
  MINIFLUX_PASSWORD: null,
  https_proxy: null,
  HTTPS_PROXY: null,
  http_proxy: null,
  all_proxy: null,
  ALL_PROXY: null,
  no_proxy: null,
  NO_PROXY: null,
  SSL_CERT_FILE: null,
  SSL_CERT_DIR: null,
  CURL_CA_BUNDLE: null
}

// The script's filesystem path, from the file:// URL Qt.resolvedUrl gives.
// Anything else comes back empty, and bash then fails the request with "No
// such file" instead of running something unexpected.
function localPath(url) {
  var s = String(url || "")
  if (s.indexOf("file://") !== 0) return ""
  try {
    return decodeURIComponent(s.slice("file://".length))
  } catch (e) {
    return ""
  }
}

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// "are these credentials good" — GET /v1/me.
function authCommand(script) {
  return [bash, script, "auth"]
}

// The latest entries, newest published first. Unread only by default; the
// setting that turns that off asks for every status so a quiet list still has
// something to show.
function entriesCommand(script, limit, unreadOnly, sortOrder) {
  var n = Number(limit)
  if (!isFinite(n) || n < 1) n = 10
  n = Math.min(100, Math.round(n))
  return [bash, script, "entries", String(n), unreadOnly ? "unread" : "all", knownSortOrder(sortOrder)]
}

function knownSortOrder(value) {
  return value === "oldest" ? "oldest" : "newest"
}

// Gathers each feed's entries together, keeping the feeds in the order they
// first appear and the entries in the order they came, so the list's sort
// order still decides what leads.
function groupByFeed(list) {
  var order = []
  var groups = {}
  for (var i = 0; i < list.length; i++) {
    var key = list[i].feedId > 0 ? "id" + list[i].feedId : "title" + list[i].feed
    if (!groups[key]) { groups[key] = []; order.push(key) }
    groups[key].push(list[i])
  }
  var out = []
  for (var j = 0; j < order.length; j++) out = out.concat(groups[order[j]])
  return out
}

// Marks a batch read in one request. Entry ids are not secret, so they can
// ride in argv; anything that is not a positive whole number is dropped.
function markReadCommand(script, ids) {
  var cmd = [bash, script, "mark"]
  for (var i = 0; i < ids.length; i++) {
    var n = Math.round(Number(ids[i]))
    if (isFinite(n) && n > 0) cmd.push(String(n))
  }
  return cmd
}

// Hands an entry to whatever third-party save service the Miniflux account
// has configured -- the same thing "s" does in the web UI.
function saveEntryCommand(script, id) {
  return [bash, script, "save-entry", String(Math.round(Number(id)))]
}

// Why a save didn't go through. 403 is the one worth naming: Miniflux answers
// that way when no save integration is enabled on the account.
function saveEntryMessage(stderr, exitCode, status) {
  if (status === 403)
    return "Miniflux has no save integration enabled for this account."
  return errorMessage(stderr, exitCode, status)
}

// Subscribes to a feed. The script checks the address answers and is (or
// points at) a feed before it subscribes. The address is typed by the user, so
// it travels in argv as one argument, never through a shell.
function addFeedCommand(script, url) {
  return [bash, script, "add-feed", String(url === undefined || url === null ? "" : url).trim()]
}

// Why a feed was not added. Exit 30 is the script's own check (nothing there
// that is a feed); a 400 or 500 on the subscribe is Miniflux's, and its own
// words say why, so they are shown when the body carries them.
function addFeedMessage(stderr, exitCode, status, body) {
  if (exitCode === 30) return "No valid feed found at that address."
  if (exitCode === 31 || (exitCode === 0 && status >= 400 && status !== 401 && status !== 403)) {
    try {
      var message = String(JSON.parse(body).error_message || "").trim()
      if (message !== "") return "Miniflux could not add the feed: " + message.slice(0, 200)
    } catch (e) {}
    return "Miniflux could not add the feed."
  }
  if (exitCode === 20) return "Can't reach Miniflux."
  return errorMessage(stderr, exitCode, status)
}

// One feed icon, by the icon id an entry carries (see parseEntries).
function iconCommand(script, id) {
  return [bash, script, "icon", String(Math.round(Number(id)))]
}

// Raster formats Qt's image readers handle. An icon in anything else is
// skipped, so its row shows the placeholder rather than a broken image.
//
// SVG is deliberately not among them. Qt's SVG decoder runs in the shell's
// own process on a document the feed's site wrote: its <image href> loads
// whatever local file path it names and paints it into the icon, it inflates
// gzip before any size limit applies, and the parser itself is a far larger
// surface than a PNG decoder. A feed whose icon is an SVG shows the
// placeholder glyph instead.
var iconTypes = ["png", "jpeg", "gif", "webp", "bmp", "x-icon", "vnd.microsoft.icon"]
// A favicon is a few KiB; anything past this is not worth holding in memory
// once per listed feed.
var iconMaxChars = 512 * 1024

// Qt sniffs the bytes rather than trusting the declared type, so the MIME
// allowlist alone would still let an SVG (or anything else) in under an
// "image/png" label. The payload's first bytes have to carry one of these
// signatures: PNG, JPEG, GIF, WebP (RIFF....WEBP), BMP, ICO.
function isRasterMagic(bytes) {
  if (bytes.length < 4) return false
  var b = bytes
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return true
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return true
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) return true
  if (b[0] === 0x42 && b[1] === 0x4d) return true
  if (b[0] === 0x00 && b[1] === 0x00 && b[2] === 0x01 && b[3] === 0x00) return true
  if (b.length >= 12 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46
      && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return true
  return false
}

// The first `count` bytes of a base64 string, decoded by hand: atob is not
// available in a .pragma library on every Qt, and only the header is needed.
var base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function base64Head(s, count) {
  var out = []
  var bits = 0, value = 0
  for (var i = 0; i < s.length && out.length < count; i++) {
    var c = base64Alphabet.indexOf(s.charAt(i))
    if (c < 0) break
    value = (value << 6) | c
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out.push((value >> bits) & 0xff)
    }
  }
  return out
}

// The icon as a data: URL for an Image, or "" when it is not one we can show.
// Miniflux sends "mime;base64,payload" without the "data:" scheme; the whole
// string is checked, so nothing from the server can turn the URL into a
// remote or local one, and the decoded header has to be a known raster
// format, so nothing can reach the SVG decoder whatever it is labelled.
function parseIcon(body) {
  var data
  try {
    data = text(JSON.parse(body).data)
  } catch (e) {
    return ""
  }
  if (data.length > iconMaxChars) return ""
  var m = /^image\/([a-z0-9.+-]+);base64,([A-Za-z0-9+\/]+={0,2})$/.exec(data)
  if (!m || iconTypes.indexOf(m[1]) < 0) return ""
  if (!isRasterMagic(base64Head(m[2], 12))) return ""
  return "data:" + data
}

// The resolved server and username, and whether a secret is on file, as JSON.
function configCommand(script) {
  return [bash, script, "config"]
}

// The web app's settings page on the user's own instance, or "" when no
// server is known. The stored address is normalised the way the script does
// it (https:// assumed, no trailing slash); anything that is still not an
// http(s) URL is refused rather than handed to openUrlExternally.
function serverSettingsUrl(server) {
  var s = text(server).trim()
  if (s === "") return ""
  if (!/^https?:\/\//i.test(s)) s = "https://" + s
  s = s.replace(/\/+$/, "")
  if (!/^https?:\/\/[^\/\s]+(\/|$)/i.test(s)) return ""
  return s + "/settings"
}

// Verifies and stores what the login form collected. The values go on stdin,
// one per line, so the password never appears in argv; a revoke the server
// refused comes back on stdout (see saveWarning).
function saveCommand(script) {
  return [bash, script, "save"]
}

// Drops everything this plugin stored.
function forgetCommand(script) {
  return [bash, script, "forget"]
}

// Every response comes back as the body with the HTTP status on its own last
// line, so a 401 can be told apart from a body that failed to parse.
function splitResponse(raw) {
  var all = String(raw || "")
  var end = all.replace(/\s+$/, "")
  var cut = end.lastIndexOf("\n")
  var status = Number(cut < 0 ? end : end.slice(cut + 1))
  return {
    status: isFinite(status) ? status : 0,
    body: cut < 0 ? "" : end.slice(0, cut)
  }
}

function parseConfig(raw) {
  var data = JSON.parse(String(raw || "").trim())
  return {
    server: text(data.server),
    username: text(data.username),
    hasSecret: data.hasSecret === true,
    store: text(data.store)
  }
}

function parseMe(body) {
  var data = JSON.parse(body)
  return { username: text(data.username) }
}

// Only the fields the list shows are pulled out, so a feed without an author
// or a published date just reads a little shorter. iconId is 0 for a feed
// Miniflux has no icon for.
function parseEntries(body) {
  var data = JSON.parse(body)
  var raw = data && data.entries ? data.entries : []
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var e = raw[i] || {}
    out.push({
      id: Number(e.id),
      title: text(e.title),
      url: text(e.url),
      feed: e.feed ? text(e.feed.title) : "",
      feedId: e.feed && isFinite(Number(e.feed.id)) ? Number(e.feed.id) : 0,
      iconId: iconId(e.feed),
      published: text(e.published_at),
      unread: text(e.status) === "unread"
    })
  }
  return out
}

function iconId(feed) {
  var n = feed && feed.icon ? Number(feed.icon.icon_id) : 0
  return isFinite(n) && n > 0 && Math.round(n) === n ? n : 0
}

function totalEntries(body) {
  try {
    var data = JSON.parse(body)
    var n = Number(data.total)
    return isFinite(n) ? n : 0
  } catch (e) {
    return 0
  }
}

// Relative for anything from the last few days, absolute after that — a feed
// list is read by how fresh an item is, not by its exact timestamp. Qt helpers
// are not reliable in a .pragma library, so this is plain JS.
function formatAge(value) {
  if (!value) return ""
  var then = new Date(value)
  if (isNaN(then.getTime())) return ""
  var mins = Math.round((Date.now() - then.getTime()) / 60000)
  if (mins < 1) return "just now"
  if (mins < 60) return mins + "m ago"
  var hours = Math.round(mins / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.round(hours / 24)
  if (days <= 6) return days + "d ago"
  return then.getFullYear() + "-" + pad(then.getMonth() + 1) + "-" + pad(then.getDate())
}

function pad(n) {
  return n < 10 ? "0" + n : String(n)
}

// Titles arrive as feed text, which may carry entities the feed author left in.
function decodeTitle(value) {
  var s = text(value)
  if (s.indexOf("&") < 0) return s
  return s.replace(/&#(\d+);/g, function (_, code) { return String.fromCharCode(Number(code)) })
          .replace(/&#x([0-9a-fA-F]+);/g, function (_, code) { return String.fromCharCode(parseInt(code, 16)) })
          .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
          .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
          .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
}

// The prelude's own exit codes say what is missing before a request is even
// attempted; curl's say the request itself went wrong.
function needsSetup(exitCode) {
  return exitCode === 10 || exitCode === 11 || exitCode === 12 || exitCode === 13
}

var insecureMessage = "Miniflux must be reached over https:// — plain http:// would send your credentials unencrypted."

function setupMessage(exitCode) {
  if (exitCode === 10) return "Enter the address of your Miniflux instance."
  if (exitCode === 11) return "Enter your Miniflux username."
  if (exitCode === 12) return "Enter your Miniflux password."
  if (exitCode === 13) return insecureMessage
  return "Sign in to your Miniflux instance."
}

function saveMessage(stderr, exitCode) {
  if (exitCode === 10) return "Server address is required."
  if (exitCode === 11) return "Username is required."
  if (exitCode === 12) return "Password is required."
  if (exitCode === 13) return insecureMessage
  if (exitCode === 21) {
    var code = answeredStatus(stderr)
    if (code === "401" || code === "403") return "Miniflux rejected that username and password."
    return "Miniflux answered " + (code || "an error") + " — check the server address."
  }
  if (exitCode === 23)
    return "Miniflux would not create an API key (answered " + (answeredStatus(stderr) || "an error") + "). Nothing was saved."
  return errorMessage(stderr, exitCode, 0)
}

// Exits 21 and 23 put the HTTP status alone on stderr. Anything that is not a
// bare three-digit code (curl's "000", a stray error line) is left out rather
// than pasted into the message.
function answeredStatus(stderr) {
  var code = String(stderr || "").trim()
  return /^[1-5][0-9][0-9]$/.test(code) ? code : ""
}

// A save that succeeded can still leave the replaced API key behind on the
// server. Returns what to tell the user about it, or "" when all went well.
function saveWarning(stdout) {
  var m = /^revoke-failed (\d+)$/m.exec(String(stdout || ""))
  if (!m) return ""
  return "Signed in. The previous API key (#" + m[1] + ") could not be revoked — delete it under Settings → API keys."
}

function errorMessage(stderr, exitCode, status) {
  if (exitCode === 13) return insecureMessage
  if (status === 401 || status === 403) return "Miniflux rejected the stored credentials — the API key may have been revoked or the password changed. Sign in again to fix it."
  if (status === 404) return "Not found — check the server address."
  if (status >= 500) return "Miniflux answered " + status + " — the server is unhappy."
  if (status > 0 && (status < 200 || status >= 300)) return "Miniflux answered " + status + "."
  // bin/miniflux-api caps stderr at 2 KiB; only its last line is shown, and
  // only the first 200 characters of that, so a long URL or path in a curl
  // error cannot stretch the panel.
  var line = String(stderr || "").split("\n").filter(function (l) { return l.trim() !== "" }).pop()
  if (line) return line.trim().slice(0, 200)
  if (exitCode === 24) return "The credential store could not be written."
  return "Request failed (exit " + exitCode + ")"
}

// Failures worth retrying on their own: curl never got an answer (exit 20:
// offline, DNS, a timeout, a network not back up after resume) or the server
// answered that it is down or busy. A 4xx, a setup code or a rejected
// credential would only fail the same way again, so those wait for the user.
function isTransient(exitCode, status) {
  if (exitCode === 20) return true
  return exitCode === 0 && (status === 429 || status >= 500)
}

// Seconds before retry n (0-based): 10, 20, 40, 80, then every 2 minutes, so a
// network that comes back is noticed quickly without polling a down server
// hard.
var retryDelays = [10, 20, 40, 80, 120]
function retryDelayMs(attempt) {
  var n = Math.max(0, Math.min(retryDelays.length - 1, Math.round(Number(attempt)) || 0))
  return retryDelays[n] * 1000
}

// What a transient failure reads as. curl's own line ("curl: (6) Could not
// resolve host: ...") is kept as the detail, minus its prefix.
function retryMessage(stderr, exitCode, status) {
  var base
  if (exitCode === 20) {
    var line = errorMessage(stderr, exitCode, status).replace(/^curl: \(\d+\)\s*/, "")
    base = /^Request failed/.test(line) ? "Can't reach Miniflux." : "Can't reach Miniflux (" + line.replace(/[.\s]+$/, "") + ")."
  } else {
    base = errorMessage(stderr, exitCode, status)
  }
  return base + " Retrying automatically."
}

// Settings arrive from shell.json, which anyone can hand-edit, and the manifest
// schema is only metadata — nothing enforces it. These bring every stored value
// back inside what the plugin supports, so a typo or an old value can neither
// break a binding nor turn the refresh timer into a tight loop.
var entryLimitMin = 1
var entryLimitMax = 100
var refreshChoices = [30, 60, 120, 180, 360, 720, 1440]
var textSizeValues = ["small", "medium", "large", "xlarge"]

function clampEntryLimit(value) {
  // Number() reads null, "" and false as 0; those mean "unset", not "one".
  if (value === null || value === "" || typeof value === "boolean") return 10
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 10
  return Math.max(entryLimitMin, Math.min(entryLimitMax, n))
}

// The nearest allowed interval, so a value from an older version still lands
// on a real choice.
function snapRefreshMinutes(value) {
  var wanted = Number(value)
  if (!isFinite(wanted)) return refreshChoices[0]
  var n = refreshChoices[0]
  for (var i = 1; i < refreshChoices.length; i++)
    if (Math.abs(refreshChoices[i] - wanted) < Math.abs(n - wanted)) n = refreshChoices[i]
  return n
}

function knownTextSize(value) {
  return textSizeValues.indexOf(value) >= 0 ? value : "medium"
}

// What open() was handed, as a plain object. The shell drops payloads on its
// way to a bar-widget panel today, but a caller can still pass one directly:
// an empty string, a non-string, malformed JSON or JSON that is not an object
// all come back as {}, so no payload can make open() throw.
function parsePayload(payloadJson) {
  if (payloadJson && typeof payloadJson === "object" && !Array.isArray(payloadJson))
    return payloadJson
  if (typeof payloadJson !== "string" || payloadJson.trim() === "") return {}
  var value
  try {
    value = JSON.parse(payloadJson)
  } catch (e) {
    return {}
  }
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}
