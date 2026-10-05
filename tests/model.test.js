// Unit tests for Model.js, run by tests/run with Node's built-in runner.
// Model.js is a QML .pragma library, so it is loaded into a fresh context with
// the pragma line dropped; every top-level function lands on that context.
"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const Model = vm.createContext({})
vm.runInContext(source.replace(/^\.pragma.*$/m, ""), Model, { filename: "Model.js" })

// Objects built inside the context have its prototypes, which deepStrictEqual
// would treat as different from ours; a JSON round trip compares plain data.
const plain = (value) => JSON.parse(JSON.stringify(value))

const script = "/opt/plugin/bin/miniflux-api"

test("commands run the script under /usr/bin/bash", () => {
  assert.equal(Model.bash, "/usr/bin/bash")
  assert.deepEqual(plain(Model.authCommand(script)), ["/usr/bin/bash", script, "auth"])
  assert.deepEqual(plain(Model.configCommand(script)), ["/usr/bin/bash", script, "config"])
  assert.deepEqual(plain(Model.saveCommand(script)), ["/usr/bin/bash", script, "save"])
  assert.deepEqual(plain(Model.forgetCommand(script)), ["/usr/bin/bash", script, "forget"])
})

test("the environment pins PATH and passes nothing else by value", () => {
  assert.equal(Model.environment.PATH, "/usr/bin:/bin")
  for (const [name, value] of Object.entries(Model.environment)) {
    if (name !== "PATH") assert.equal(value, null, name)
  }
  for (const name of ["BASH_ENV", "ENV", "CURL_HOME", "LD_PRELOAD", "SHELLOPTS"])
    assert.ok(!(name in Model.environment), name)
})

test("localPath only accepts file:// URLs", () => {
  assert.equal(Model.localPath("file:///opt/a%20b/bin/miniflux-api"), "/opt/a b/bin/miniflux-api")
  assert.equal(Model.localPath("qrc:/bin/miniflux-api"), "")
  assert.equal(Model.localPath("/opt/bin/miniflux-api"), "")
  assert.equal(Model.localPath("file:///bad%E0%A4%A"), "")
  assert.equal(Model.localPath(null), "")
})

test("entriesCommand clamps the limit and picks the filter", () => {
  const args = (limit, unread) => plain(Model.entriesCommand(script, limit, unread)).slice(3)
  assert.deepEqual(args(25, true), ["25", "unread"])
  assert.deepEqual(args(25, false), ["25", "all"])
  assert.deepEqual(args(0, true), ["10", "unread"])
  assert.deepEqual(args("abc", true), ["10", "unread"])
  assert.deepEqual(args(1000, true), ["100", "unread"])
  assert.deepEqual(args(4.6, true), ["5", "unread"])
})

test("markReadCommand keeps positive whole ids only", () => {
  const ids = plain(Model.markReadCommand(script, [3, "7", -1, 0, "x", 2.4, NaN, "1; rm -rf ~"]))
  assert.deepEqual(ids.slice(3), ["3", "7", "2"])
})

test("saveEntryCommand rounds the id", () => {
  assert.deepEqual(plain(Model.saveEntryCommand(script, 41.6)).slice(2), ["save-entry", "42"])
})

test("iconCommand rounds the id", () => {
  assert.deepEqual(plain(Model.iconCommand(script, 7.4)).slice(2), ["icon", "7"])
})

test("parseIcon only builds base64 image data URLs", () => {
  const icon = (data) => JSON.stringify({ id: 1, data: data, mime_type: "x" })
  assert.equal(Model.parseIcon(icon("image/png;base64,iVBORw0KGgo=")), "data:image/png;base64,iVBORw0KGgo=")
  assert.equal(Model.parseIcon(icon("image/svg+xml;base64,PHN2Zz4=")), "data:image/svg+xml;base64,PHN2Zz4=")
  assert.equal(Model.parseIcon(icon("text/html;base64,PGI+")), "")
  assert.equal(Model.parseIcon(icon("image/tiff;base64,AAAA")), "")
  assert.equal(Model.parseIcon(icon("image/png,<svg>")), "")
  assert.equal(Model.parseIcon(icon("image/png;base64,AA==\nhttps://evil.example/")), "")
  assert.equal(Model.parseIcon(icon("https://evil.example/icon.png")), "")
  assert.equal(Model.parseIcon(icon("image/png;base64," + "A".repeat(600 * 1024))), "")
  assert.equal(Model.parseIcon("{}"), "")
  assert.equal(Model.parseIcon("<html>"), "")
})

test("splitResponse takes the status from the last line", () => {
  assert.deepEqual(plain(Model.splitResponse('{"a":1}\n200\n')), { status: 200, body: '{"a":1}' })
  assert.deepEqual(plain(Model.splitResponse("line one\nline two\n401")), { status: 401, body: "line one\nline two" })
  assert.deepEqual(plain(Model.splitResponse("")), { status: 0, body: "" })
  assert.deepEqual(plain(Model.splitResponse("no status here")), { status: 0, body: "" })
})

test("parseConfig and parseMe read only the fields they need", () => {
  assert.deepEqual(plain(Model.parseConfig(' {"server":"https://m.example","username":"ann","hasSecret":true,"store":"~/.config/omarchy/miniflux"}\n')),
    { server: "https://m.example", username: "ann", hasSecret: true, store: "~/.config/omarchy/miniflux" })
  assert.deepEqual(plain(Model.parseConfig('{"hasSecret":"true"}')), { server: "", username: "", hasSecret: false, store: "" })
  assert.throws(() => Model.parseConfig("not json"))
  assert.deepEqual(plain(Model.parseMe('{"username":"ann","is_admin":true}')), { username: "ann" })
})

test("parseEntries tolerates missing fields", () => {
  const body = JSON.stringify({
    total: 2,
    entries: [
      { id: 5, title: "One", url: "https://a.example/1", feed: { title: "Feed", icon: { feed_id: 2, icon_id: 8 } }, published_at: "2026-01-02T03:04:05Z", status: "unread" },
      { id: "6", status: "read", feed: { icon: { icon_id: "x" } } },
      null
    ]
  })
  assert.deepEqual(plain(Model.parseEntries(body)), [
    { id: 5, title: "One", url: "https://a.example/1", feed: "Feed", iconId: 8, published: "2026-01-02T03:04:05Z", unread: true },
    { id: 6, title: "", url: "", feed: "", iconId: 0, published: "", unread: false },
    { id: null, title: "", url: "", feed: "", iconId: 0, published: "", unread: false }
  ])
  assert.deepEqual(plain(Model.parseEntries("{}")), [])
  assert.throws(() => Model.parseEntries("<html>"))
})

test("totalEntries never throws", () => {
  assert.equal(Model.totalEntries('{"total":42}'), 42)
  assert.equal(Model.totalEntries('{"total":"x"}'), 0)
  assert.equal(Model.totalEntries("<html>"), 0)
})

test("formatAge is relative for a week, then a date", () => {
  const ago = (ms) => new Date(Date.now() - ms).toISOString()
  const minute = 60000
  assert.equal(Model.formatAge(""), "")
  assert.equal(Model.formatAge("not a date"), "")
  assert.equal(Model.formatAge(ago(10 * 1000)), "just now")
  assert.equal(Model.formatAge(ago(5 * minute)), "5m ago")
  assert.equal(Model.formatAge(ago(3 * 60 * minute)), "3h ago")
  assert.equal(Model.formatAge(ago(2 * 24 * 60 * minute)), "2d ago")
  const old = new Date(Date.now() - 30 * 24 * 60 * minute)
  const pad = (n) => String(n).padStart(2, "0")
  assert.equal(Model.formatAge(old.toISOString()),
    `${old.getFullYear()}-${pad(old.getMonth() + 1)}-${pad(old.getDate())}`)
})

test("decodeTitle decodes entities once", () => {
  assert.equal(Model.decodeTitle("Tom &amp; Jerry"), "Tom & Jerry")
  assert.equal(Model.decodeTitle("&lt;b&gt; &quot;x&quot; &apos;y&apos;&nbsp;z"), "<b> \"x\" 'y' z")
  assert.equal(Model.decodeTitle("&#8212; &#x2014;"), "— —")
  assert.equal(Model.decodeTitle("&amp;lt;"), "&lt;")
  assert.equal(Model.decodeTitle(null), "")
})

test("setup codes map to prompts", () => {
  for (const code of [10, 11, 12, 13]) assert.ok(Model.needsSetup(code), String(code))
  for (const code of [0, 20, 21, 24, 64]) assert.ok(!Model.needsSetup(code), String(code))
  assert.match(Model.setupMessage(10), /address/)
  assert.match(Model.setupMessage(13), /https:\/\//)
  assert.match(Model.setupMessage(99), /Sign in/)
})

test("answeredStatus only quotes a bare three-digit code", () => {
  assert.equal(Model.answeredStatus("401\n"), "401")
  assert.equal(Model.answeredStatus("000"), "")
  assert.equal(Model.answeredStatus("curl: (6) Could not resolve host"), "")
  assert.equal(Model.answeredStatus("401 and more"), "")
})

test("saveMessage explains each exit code", () => {
  assert.equal(Model.saveMessage("401", 21), "Miniflux rejected that username and password.")
  assert.equal(Model.saveMessage("302", 21), "Miniflux answered 302 — check the server address.")
  assert.equal(Model.saveMessage("junk", 21), "Miniflux answered an error — check the server address.")
  assert.match(Model.saveMessage("500", 23), /answered 500\)\. Nothing was saved\./)
  assert.equal(Model.saveMessage("", 13), Model.insecureMessage)
})

test("saveWarning names a key that could not be revoked", () => {
  assert.equal(Model.saveWarning(""), "")
  assert.match(Model.saveWarning("revoke-failed 17\n"), /#17/)
  assert.equal(Model.saveWarning("revoke-failed 17; rm"), "")
})

test("errorMessage prefers the status, then the last stderr line", () => {
  assert.match(Model.errorMessage("", 0, 401), /rejected the stored credentials/)
  assert.equal(Model.errorMessage("", 0, 404), "Not found — check the server address.")
  assert.equal(Model.errorMessage("", 0, 502), "Miniflux answered 502 — the server is unhappy.")
  assert.equal(Model.errorMessage("", 0, 302), "Miniflux answered 302.")
  assert.equal(Model.errorMessage("first\nlast line  \n\n", 20, 0), "last line")
  assert.equal(Model.errorMessage("x".repeat(500), 20, 0).length, 200)
  assert.equal(Model.errorMessage("", 24, 0), "The credential store could not be written.")
  assert.equal(Model.errorMessage("", 20, 0), "Request failed (exit 20)")
  assert.equal(Model.saveEntryMessage("", 0, 403), "Miniflux has no save integration enabled for this account.")
})

test("isTransient retries unreachable and down servers only", () => {
  assert.equal(Model.isTransient(20, 0), true)
  assert.equal(Model.isTransient(0, 502), true)
  assert.equal(Model.isTransient(0, 429), true)
  assert.equal(Model.isTransient(0, 401), false)
  assert.equal(Model.isTransient(0, 404), false)
  assert.equal(Model.isTransient(10, 0), false)
  assert.equal(Model.isTransient(22, 0), false)
})

test("retryDelayMs backs off and caps at two minutes", () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 50].map(Model.retryDelayMs), [10000, 20000, 40000, 80000, 120000, 120000, 120000])
  assert.equal(Model.retryDelayMs(-3), 10000)
  assert.equal(Model.retryDelayMs("x"), 10000)
})

test("retryMessage keeps curl's detail and says it will retry", () => {
  assert.equal(Model.retryMessage("curl: (7) Failed to connect to rss.example.test port 443\n", 20, 0),
    "Can't reach Miniflux (Failed to connect to rss.example.test port 443). Retrying automatically.")
  assert.equal(Model.retryMessage("", 20, 0), "Can't reach Miniflux. Retrying automatically.")
  assert.equal(Model.retryMessage("", 0, 503), "Miniflux answered 503 — the server is unhappy. Retrying automatically.")
})

test("clampEntryLimit keeps 1-100 and treats unset as the default", () => {
  const cases = [[25, 25], ["7", 7], [0, 1], [-5, 1], [500, 100], [3.4, 3],
    [null, 10], ["", 10], [true, 10], [false, 10], ["abc", 10], [undefined, 10], [Infinity, 10]]
  for (const [input, expected] of cases) assert.equal(Model.clampEntryLimit(input), expected, String(input))
})

test("snapRefreshMinutes lands on an offered interval", () => {
  const cases = [[30, 30], [45, 30], [50, 60], [1, 30], [100000, 1440], ["120", 120], ["x", 30], [null, 30]]
  for (const [input, expected] of cases) assert.equal(Model.snapRefreshMinutes(input), expected, String(input))
})

test("knownTextSize falls back to medium", () => {
  for (const size of ["small", "medium", "large", "xlarge"]) assert.equal(Model.knownTextSize(size), size)
  for (const size of ["huge", "", null, 3, "Medium"]) assert.equal(Model.knownTextSize(size), "medium")
})

test("parsePayload returns an object for any input", () => {
  for (const input of [undefined, null, "", "   ", "{bad", 42, "[1]", '"x"', "null", [1], true])
    assert.deepEqual(plain(Model.parsePayload(input)), {}, String(input))
  assert.deepEqual(plain(Model.parsePayload('{"a":1}')), { a: 1 })
  const object = { b: 2 }
  assert.equal(Model.parsePayload(object), object)
})
