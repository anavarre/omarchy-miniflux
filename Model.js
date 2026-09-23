.pragma library

// Miniflux REST API: https://miniflux.app/docs/api.html
//
// Credentials are resolved in the shell, never held in QML. The server and
// username live in a plain config file; the secret is either an API key
// minted at setup (X-Auth-Token, the API's preferred mechanism) or, when the
// instance is too old to mint one, the password kept for HTTP basic auth.
// curl reads the header or `user =` from a config file on stdin (-K -), so the
// secret never appears in argv or in `ps`.
//
// Exit codes: 10 no server, 11 no username, 12 no secret, 20 request failed,
// 21 credentials rejected.
var store = '"${MINIFLUX_PLUGIN_DIR:-$HOME/.config/omarchy/miniflux}"'

// A curl config that writes the HTTP status on its own last line, so the
// caller can tell 200 from 401 without a second request.
var statusLine = 'write-out = "\\\\n%%{http_code}"\\n'

var prelude = [
  'set -u',
  'store=' + store,
  'saved() { [ -r "$store/config" ] && sed -n "s|^$1=||p" "$store/config" | head -n1; }',
  'secret() { [ -r "$1" ] && head -n1 "$1" | tr -d "\\r\\n"; }',
  'server="${MINIFLUX_SERVER:-}"',
  '[ -n "$server" ] || server=$(saved server)',
  'username="${MINIFLUX_USERNAME:-}"',
  '[ -n "$username" ] || username=$(saved username)',
  'token="${MINIFLUX_API_KEY:-}"',
  '[ -n "$token" ] || token=$(secret "$store/token")',
  'password="${MINIFLUX_PASSWORD:-}"',
  '[ -n "$password" ] || password=$(secret "$store/password")',
  'case "$server" in http://*|https://*) ;; "") ;; *) server="https://$server" ;; esac',
  'server="${server%/}"',
  '[ -n "$server" ] || exit 10',
  '[ -n "$token" ] || [ -n "$username" ] || exit 11',
  '[ -n "$token" ] || [ -n "$password" ] || exit 12',
  'auth() {',
  '  if [ -n "$token" ]; then printf \'header = "X-Auth-Token: %s"\\n\' "$token"',
  '  else printf \'user = "%s:%s"\\n\' "$username" "$password"; fi',
  '}',
  'api() {',
  '  path="$1"; shift',
  '  { auth; printf \'silent\\nshow-error\\nheader = "Accept: application/json"\\n' + statusLine + '\'; } |',
  '    curl -K - "$@" "$server$path" || exit 20',
  '}'
].join("\n")

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// "are these credentials good" — GET /v1/me.
function authCommand() {
  return ["bash", "-c", prelude + '\napi /v1/me']
}

// The latest entries, newest published first. Unread only by default; the
// setting that turns that off asks for every status so a quiet list still has
// something to show.
function entriesCommand(limit, unreadOnly) {
  var n = Number(limit)
  if (!isFinite(n) || n < 1) n = 20
  n = Math.min(100, Math.round(n))
  var query = "/v1/entries?order=published_at&direction=desc&limit=" + n
  if (unreadOnly) query += "&status=unread"
  return ["bash", "-c", prelude + '\napi "$1"', "miniflux", query]
}

// PUT /v1/entries marks a batch in one request. Entry ids are not secret, so
// the body can ride in argv.
function markReadCommand(ids) {
  var list = []
  for (var i = 0; i < ids.length; i++) {
    var n = Number(ids[i])
    if (isFinite(n)) list.push(Math.round(n))
  }
  var body = '{"entry_ids":[' + list.join(",") + '],"status":"read"}'
  return ["bash", "-c",
    prelude + '\napi /v1/entries -X PUT -H "Content-Type: application/json" --data-binary "$1"',
    "miniflux", body]
}

// What the settings form should show: the resolved server and username, and
// whether a secret is on file. The secret itself is never printed.
function configCommand() {
  return ["bash", "-c", [
    'set -u',
    'store=' + store,
    'saved() { [ -r "$store/config" ] && sed -n "s|^$1=||p" "$store/config" | head -n1; }',
    'server="${MINIFLUX_SERVER:-}"; [ -n "$server" ] || server=$(saved server)',
    'username="${MINIFLUX_USERNAME:-}"; [ -n "$username" ] || username=$(saved username)',
    'has=false',
    'if [ -n "${MINIFLUX_API_KEY:-}" ] || [ -s "$store/token" ] || [ -s "$store/password" ]; then has=true; fi',
    'esc() { printf \'%s\' "$1" | sed \'s|\\\\|\\\\\\\\|g; s|"|\\\\"|g\'; }',
    'printf \'{"server":"%s","username":"%s","hasSecret":%s}\\n\' "$(esc "$server")" "$(esc "$username")" "$has"'
  ].join("\n")]
}

// Writes what the login form collected. Values arrive on stdin, one per line,
// so the password never appears in argv. The login is verified before anything
// is stored, and an API key is minted from it when the instance supports one
// (Miniflux 2.2.9+) so the password does not have to be kept at all.
function saveCommand() {
  return ["bash", "-c", [
    'set -u',
    'umask 077',
    'store=' + store,
    'IFS= read -r server || true',
    'IFS= read -r username || true',
    'IFS= read -r password || true',
    'case "$server" in http://*|https://*) ;; *) server="https://$server" ;; esac',
    'server="${server%/}"',
    '[ -n "$server" ] || exit 10',
    '[ -n "$username" ] || exit 11',
    '[ -n "$password" ] || exit 12',
    'auth() { printf \'user = "%s:%s"\\nsilent\\nshow-error\\nheader = "Accept: application/json"\\n' + statusLine + '\' "$username" "$password"; }',
    'me=$(auth | curl -K - "$server/v1/me") || exit 20',
    'code=$(printf \'%s\' "$me" | tail -n1)',
    '[ "$code" = "200" ] || { printf \'%s\\n\' "$code" >&2; exit 21; }',
    'mkdir -p "$store" && chmod 700 "$store"',
    'printf \'server=%s\\nusername=%s\\n\' "$server" "$username" > "$store/config"',
    'chmod 600 "$store/config"',
    'key=$(auth | curl -K - -X POST -H "Content-Type: application/json" --data-binary \'{"description":"Omarchy bar widget"}\' "$server/v1/api-keys") || key=""',
    'tok=""',
    'if [ "$(printf \'%s\' "$key" | tail -n1)" = "201" ]; then',
    '  tok=$(printf \'%s\' "$key" | sed -n \'s/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' | head -n1)',
    'fi',
    'if [ -n "$tok" ]; then',
    '  printf \'%s\' "$tok" > "$store/token"; chmod 600 "$store/token"; rm -f "$store/password"',
    'else',
    '  printf \'%s\' "$password" > "$store/password"; chmod 600 "$store/password"; rm -f "$store/token"',
    'fi'
  ].join("\n")]
}

// Drops everything this plugin stored. Credentials from the environment are
// not ours to remove.
function forgetCommand() {
  return ["bash", "-c", [
    'store=' + store,
    'rm -f "$store/config" "$store/token" "$store/password"'
  ].join("\n")]
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
    hasSecret: data.hasSecret === true
  }
}

function parseMe(body) {
  var data = JSON.parse(body)
  return { username: text(data.username) }
}

// Only the fields the list shows are pulled out, so a feed without an author
// or a published date just reads a little shorter.
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
      published: text(e.published_at),
      unread: text(e.status) === "unread"
    })
  }
  return out
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
  return exitCode === 10 || exitCode === 11 || exitCode === 12
}

function setupMessage(exitCode) {
  if (exitCode === 10) return "Enter the address of your Miniflux instance."
  if (exitCode === 11) return "Enter your Miniflux username."
  if (exitCode === 12) return "Enter your Miniflux password."
  return "Sign in to your Miniflux instance."
}

function saveMessage(stderr, exitCode) {
  if (exitCode === 10) return "Server address is required."
  if (exitCode === 11) return "Username is required."
  if (exitCode === 12) return "Password is required."
  if (exitCode === 21) {
    var code = String(stderr || "").trim()
    if (code === "401" || code === "403") return "Miniflux rejected that username and password."
    return "Miniflux answered " + (code || "an error") + " — check the server address."
  }
  return errorMessage(stderr, exitCode, 0)
}

function errorMessage(stderr, exitCode, status) {
  if (status === 401 || status === 403) return "Miniflux rejected the stored credentials."
  if (status === 404) return "Not found — check the server address."
  if (status >= 500) return "Miniflux answered " + status + " — the server is unhappy."
  if (status > 0 && (status < 200 || status >= 300)) return "Miniflux answered " + status + "."
  var line = String(stderr || "").split("\n").filter(function (l) { return l.trim() !== "" }).pop()
  if (line) return line.trim().slice(0, 200)
  return "Request failed (exit " + exitCode + ")"
}
