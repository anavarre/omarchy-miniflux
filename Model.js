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
// Exit codes: 10 no server, 11 no username, 12 no secret, 13 server is plain
// http:// off this machine, 20 request failed, 21 credentials rejected,
// 22 response too large, 23 API key could not be minted.
var store = '"${MINIFLUX_PLUGIN_DIR:-$HOME/.config/omarchy/miniflux}"'

// A curl config that writes the HTTP status on its own last line, so the
// caller can tell 200 from 401 without a second request.
var statusLine = 'write-out = "\\\\n%%{http_code}"\\n'

// Basic auth and X-Auth-Token are both cleartext on the wire, so a plain
// http:// server is refused unless it is loopback, where nothing leaves the
// machine. The host is cut out of the URL (dropping any userinfo, so
// http://localhost@evil.example is not mistaken for localhost) and matched
// exactly. curl is never told to follow redirects, and fetch() below pins the
// protocol and ignores ~/.curlrc, so an https:// server cannot bounce a request
// (and the X-Auth-Token header curl would carry along) down to http:// either.
var plainFn = [
  'plain() {',
  '  case "$1" in http://*) ;; *) return 1 ;; esac',
  '  h=${1#http://}; h=${h%%/*}; h=${h%%\\?*}; h=${h%%#*}; h=${h##*@}',
  '  case "$h" in "[::1]"|"[::1]:"*) return 1 ;; esac',
  '  h=${h%:*}',
  '  case "$h" in',
  '    localhost) return 1 ;;',
  '    127.*) case "$h" in *[!0-9.]*) return 0 ;; esac; return 1 ;;',
  '  esac',
  '  return 0',
  '}'
].join("\n")

// Every request gets a connect timeout, a total deadline and a size cap, so a
// slow or oversized answer cannot hold a request open or balloon the stdout the
// panel collects. --max-filesize stops early when the server announces a size;
// head -c is the backstop for a body that doesn't, reading one byte past the cap
// so an overrun can be told apart from a body that merely fills it. The HTTP
// status line from write-out counts toward the cap, which is generous enough
// (100 entries with full content) not to matter.
//
// -q must come first: it stops curl reading ~/.curlrc, which could otherwise
// switch on `location` or `insecure` and undo all of the above. --proto pins
// the one scheme the server was accepted with, and --proto-redir keeps any
// redirect on https:// should one ever be followed.
var maxBytes = 16 * 1024 * 1024
var fetchFn = [
  'cap=' + maxBytes,
  'fetch() {',
  '  local LC_ALL=C out rc=0 proto==https',
  '  case "$server" in http://*) proto==http ;; esac',
  '  out=$(curl -q --proto "$proto" --proto-redir =https --connect-timeout 10 --max-time 30 --max-filesize "$cap" -K - "$@" | head -c $((cap + 1)); exit "${PIPESTATUS[0]}") || rc=$?',
  '  if [ "$rc" -eq 63 ] || [ "${#out}" -gt "$cap" ]; then',
  '    printf \'Miniflux sent more than %s MiB.\\n\' $((cap / 1048576)) >&2; return 22',
  '  fi',
  '  [ "$rc" -eq 0 ] || return 20',
  '  printf \'%s\\n\' "$out"',
  '}'
].join("\n")

// curl's -K parser reads `name = "value"` with backslash escapes, so a secret
// carrying a quote or a backslash has to be escaped or it truncates the line.
// Every value is read one line at a time or has CR/LF stripped (oneLine), so
// no newline can reach this to start a new directive; this is about passwords
// that are merely awkward, not hostile.
var oneLineFn = 'oneLine() { printf \'%s\' "$1" | tr -d "\\r\\n"; }'
var escFn = 'esc() { printf \'%s\' "$1" | sed \'s|\\\\|\\\\\\\\|g; s|"|\\\\"|g\'; }'

var prelude = [
  'set -u',
  'store=' + store,
  'saved() { [ -r "$store/config" ] && sed -n "s|^$1=||p" "$store/config" | head -n1; }',
  'secret() { [ -r "$1" ] && head -n1 "$1" | tr -d "\\r\\n"; }',
  'server="${MINIFLUX_SERVER:-}"',
  '[ -n "$server" ] || server=$(saved server)',
  oneLineFn,
  'username=$(oneLine "${MINIFLUX_USERNAME:-}")',
  '[ -n "$username" ] || username=$(saved username)',
  'token=$(oneLine "${MINIFLUX_API_KEY:-}")',
  '[ -n "$token" ] || token=$(secret "$store/token")',
  'password=$(oneLine "${MINIFLUX_PASSWORD:-}")',
  '[ -n "$password" ] || password=$(secret "$store/password")',
  'case "$server" in http://*|https://*) ;; "") ;; *) server="https://$server" ;; esac',
  'server="${server%/}"',
  '[ -n "$server" ] || exit 10',
  plainFn,
  'plain "$server" && exit 13',
  '[ -n "$token" ] || [ -n "$username" ] || exit 11',
  '[ -n "$token" ] || [ -n "$password" ] || exit 12',
  escFn,
  fetchFn,
  'auth() {',
  '  if [ -n "$token" ]; then printf \'header = "X-Auth-Token: %s"\\n\' "$(esc "$token")"',
  '  else printf \'user = "%s:%s"\\n\' "$(esc "$username")" "$(esc "$password")"; fi',
  '}',
  'api() {',
  '  path="$1"; shift',
  '  { auth; printf \'silent\\nshow-error\\nheader = "Accept: application/json"\\n' + statusLine + '\'; } |',
  '    fetch "$@" "$server$path" || exit $?',
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
  if (!isFinite(n) || n < 1) n = 10
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

// POST /v1/entries/{id}/save hands the entry to whatever third-party save
// service the Miniflux account has configured -- the same thing "s" does in
// the web UI. The id is a number we round ourselves, so it is safe in the URL.
function saveEntryCommand(id) {
  var n = Math.round(Number(id))
  if (!isFinite(n)) return []
  return ["bash", "-c", prelude + '\napi "$1" -X POST', "miniflux", "/v1/entries/" + n + "/save"]
}

// Why a save didn't go through. 403 is the one worth naming: Miniflux answers
// that way when no save integration is enabled on the account.
function saveEntryMessage(stderr, exitCode, status) {
  if (status === 403)
    return "Miniflux has no save integration enabled for this account."
  return errorMessage(stderr, exitCode, status)
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
    escFn,
    'printf \'{"server":"%s","username":"%s","hasSecret":%s}\\n\' "$(esc "$server")" "$(esc "$username")" "$has"'
  ].join("\n")]
}

// Writes what the login form collected. Values arrive on stdin, one per line,
// so the password never appears in argv. The login is verified before anything
// is stored, and an API key is minted from it when the instance supports one
// (Miniflux 2.2.9+) so the password does not have to be kept at all.
//
// The password is kept only when the instance has no key endpoint (404/405).
// Any other mint failure stops before the store is touched, rather than
// quietly downgrading to a stored password. Miniflux requires key descriptions
// to be unique per user, so each one carries the machine name and the time.
//
// The minted key's id is kept in token-id so the key it replaces can be
// revoked. That happens last, only once the new token is on disk, and failing
// to revoke never fails the save: a leftover key is cheaper than no working
// one. Keys are never matched by description, which two machines can share.
// A revoke the server refuses is reported on stdout as `revoke-failed <id>`
// (see saveWarning) so the leftover key can be deleted by hand; 404 means it
// is already gone. The shell's PID keeps two saves in one second apart.
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
    plainFn,
    'plain "$server" && exit 13',
    '[ -n "$username" ] || exit 11',
    '[ -n "$password" ] || exit 12',
    escFn,
    fetchFn,
    'auth() { printf \'user = "%s:%s"\\nsilent\\nshow-error\\nheader = "Accept: application/json"\\n' + statusLine + '\' "$(esc "$username")" "$(esc "$password")"; }',
    'me=$(auth | fetch "$server/v1/me") || exit $?',
    'code=$(printf \'%s\' "$me" | tail -n1)',
    '[ "$code" = "200" ] || { printf \'%s\\n\' "$code" >&2; exit 21; }',
    'desc="Omarchy bar widget ($(uname -n | tr -cd "A-Za-z0-9.-") $(date -u +%Y-%m-%dT%H:%M:%SZ) $$)"',
    'key=$(auth | fetch -X POST -H "Content-Type: application/json" --data-binary "{\\"description\\":\\"$desc\\"}" "$server/v1/api-keys") || exit $?',
    'kcode=$(printf \'%s\' "$key" | tail -n1)',
    'tok=""; kid=""',
    'case "$kcode" in',
    '  201) tok=$(printf \'%s\' "$key" | sed -n \'s/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p\' | head -n1)',
    '       kid=$(printf \'%s\' "$key" | sed -n \'s/.*"id"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p\' | head -n1)',
    '       [ -n "$tok" ] || { printf \'%s\\n\' "$kcode" >&2; exit 23; } ;;',
    '  404|405) ;;',
    '  *) printf \'%s\\n\' "$kcode" >&2; exit 23 ;;',
    'esac',
    'old=""; [ -r "$store/token-id" ] && old=$(head -n1 "$store/token-id" | tr -cd "0-9")',
    'oldserver=""; [ -r "$store/config" ] && oldserver=$(sed -n "s/^server=//p" "$store/config" | head -n1)',
    'mkdir -p "$store" && chmod 700 "$store"',
    'printf \'server=%s\\nusername=%s\\n\' "$server" "$username" > "$store/config"',
    'chmod 600 "$store/config"',
    'if [ -n "$tok" ]; then',
    '  printf \'%s\' "$tok" > "$store/token"; chmod 600 "$store/token"; rm -f "$store/password"',
    '  if [ -n "$kid" ]; then printf \'%s\' "$kid" > "$store/token-id"; chmod 600 "$store/token-id"; else rm -f "$store/token-id"; fi',
    '  if [ -n "$old" ] && [ "$old" != "$kid" ] && [ "$oldserver" = "$server" ]; then',
    '    rv=$(auth | fetch -X DELETE "$server/v1/api-keys/$old" 2>/dev/null) || rv=""',
    '    case "$(printf \'%s\' "$rv" | tail -n1)" in 204|404) ;; *) printf \'revoke-failed %s\\n\' "$old" ;; esac',
    '  fi',
    'else',
    '  printf \'%s\' "$password" > "$store/password"; chmod 600 "$store/password"; rm -f "$store/token" "$store/token-id"',
    'fi'
  ].join("\n")]
}

// Drops everything this plugin stored. Credentials from the environment are
// not ours to remove.
function forgetCommand() {
  return ["bash", "-c", [
    'set -u',
    'store=' + store,
    'rm -f "$store/config" "$store/token" "$store/token-id" "$store/password"'
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
    var code = String(stderr || "").trim()
    if (code === "401" || code === "403") return "Miniflux rejected that username and password."
    return "Miniflux answered " + (code || "an error") + " — check the server address."
  }
  if (exitCode === 23) {
    var answered = String(stderr || "").trim()
    return "Miniflux would not create an API key (answered " + (answered || "an error") + "). Nothing was saved."
  }
  return errorMessage(stderr, exitCode, 0)
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
  var line = String(stderr || "").split("\n").filter(function (l) { return l.trim() !== "" }).pop()
  if (line) return line.trim().slice(0, 200)
  return "Request failed (exit " + exitCode + ")"
}
