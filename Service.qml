import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one process-wide owner of everything fetched from Miniflux: sign-in
// state, the entry list, the refresh timer and the mark/save requests. The bar
// widget exists once per monitor and so does its panel; if each of them polled
// on its own, N monitors would mean N timers and N fetches, and marking an
// entry read on one screen would leave it listed on the others. They read this
// instead and keep only what is local to one screen: selection, hover, which
// section is up, and the sign-in form's fields.
Item {
  id: root

  // Injected by the host after load.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  // The request script that ships next to this file (see bin/miniflux-api).
  readonly property string api: Model.localPath(Qt.resolvedUrl("bin/miniflux-api"))

  // Pushed in by the bar widget, which is the only side the shell injects user
  // settings into. Every monitor's widget reads the same shell.json entry, so
  // whichever pushes last pushes the same values.
  property int entryLimit: 10
  property bool unreadOnly: true
  property int refreshMinutes: 30
  // 30 minutes up to a day, so the interval can never hammer the instance.
  readonly property int refreshMin: 30

  // "unknown" until the first check, then "checking" / "ok" / "error".
  // Everything else is gated on "ok", so a credential problem is reported
  // once, as sign-in, instead of once per request as an opaque 401.
  property string authState: "unknown"
  // A setup hint ("enter your username") is advice and reads as such; an
  // error ("Miniflux rejected the stored credentials") is a failure and reads
  // in the urgent color. Neither is cleared by starting another check, so the
  // form stays put while the check it triggered is in flight.
  property string authHint: ""
  property string authError: ""
  property string account: ""
  readonly property bool authenticated: authState === "ok"

  property bool saving: false
  property bool hasSecret: false
  // What is on file, for pre-filling the sign-in form. Never the secret.
  property string storedServer: ""
  property string storedUsername: ""

  property bool loading: false
  property string errorText: ""
  // Transient confirmation for the save shortcut, shown under the header.
  property string saveNotice: ""
  // A notice that asks for action (a key that could not be revoked) outlasts
  // a closed panel; a plain "Saved." does not.
  property bool saveNoticeSticky: false
  property bool saveEntryBusy: false
  property var entries: []
  property int total: 0

  // Entries being marked read are dropped from the list as soon as the
  // request goes out — the round trip is the slow part, and a row that lingers
  // invites a second click on something already gone. A failure puts the whole
  // list back by refetching.
  // Ids in flight or queued, as a map. A fetch that lands meanwhile still has
  // them unread, so they are filtered out of it rather than flickering back.
  property var pending: ({})
  // Ids marked while a request was already out. Sent as one batch when it
  // returns, so a quick second click is never dropped.
  property var markQueue: []

  // Requests finish in whatever order the network allows. Each process
  // records the generation it started under and drops its result if that has
  // moved on: session changes on sign-in and forget, so nothing fetched with
  // the old credentials lands after them; listGeneration also changes with
  // the list settings, so a fetch for the old limit never overwrites a newer
  // one.
  property int session: 0
  property int listGeneration: 0
  // A refresh asked for while one is in flight runs once it returns, instead
  // of being dropped — its settings or the server may have changed since.
  property bool refreshQueued: false
  // Same for a sign-in check asked for while one is running.
  property bool authRecheck: false

  // Set when a background refresh turns up entry ids that were not in the
  // previous list while no panel was open. The bar widget reads it to paint
  // its dot; opening a panel is what clears it, since by then you have seen
  // them.
  property bool hasNewEntries: false
  // Ids from the last fetch, rebuilt each time so the map cannot grow without
  // bound. Null until the first fetch lands — that one only sets the baseline,
  // so signing in does not immediately claim everything is new.
  property var seenIds: null
  // How many monitors currently show the panel.
  property int openPanels: 0

  readonly property int listedUnread: {
    var n = 0
    for (var i = 0; i < root.entries.length; i++) if (root.entries[i].unread) n++
    return n
  }

  // A sign-in that went through, and a forget that finished. Panels use these
  // to reset their own form; the shared state is already updated.
  signal signedIn()
  signal forgotten()

  function panelOpened() {
    root.openPanels++
    root.clearNewEntries()
    if (root.saveNotice !== "" && !saveNoticeTimer.running) saveNoticeTimer.restart()
  }

  // A save confirmation belongs to the panel it was shown in. Once the last
  // one closes it is dropped, rather than reappearing on the next open with
  // part of its time already spent. A sticky notice is kept instead, with its
  // clock stopped, and gets its full time again on the next open.
  function panelClosed() {
    root.openPanels = Math.max(0, root.openPanels - 1)
    if (root.openPanels > 0) return
    saveNoticeTimer.stop()
    if (!root.saveNoticeSticky) root.saveNotice = ""
  }

  // Folds a freshly fetched list into the baseline and reports whether any of
  // it was unseen.
  function noteEntries(list) {
    var seen = {}
    var fresh = false
    for (var i = 0; i < list.length; i++) {
      seen[list[i].id] = true
      if (root.seenIds !== null && !root.seenIds[list[i].id]) fresh = true
    }
    root.seenIds = seen
    if (fresh && root.openPanels === 0) root.hasNewEntries = true
  }

  function clearNewEntries() {
    root.hasNewEntries = false
    var seen = {}
    for (var i = 0; i < root.entries.length; i++) seen[root.entries[i].id] = true
    root.seenIds = seen
  }

  function clearAuthMessages() {
    root.authError = ""
    root.authHint = ""
  }

  function loadConfig() {
    if (configProcess.running) return
    configProcess.session = root.session
    configProcess.command = Model.configCommand(root.api)
    configProcess.running = true
  }

  function newSession() {
    root.session++
    root.listGeneration++
    root.refreshQueued = false
    root.markQueue = []
    root.pending = ({})
  }

  function signIn(server, username, password) {
    if (root.saving || forgetProcess.running) return
    root.saving = true
    root.clearAuthMessages()
    saveProcess.payload = String(server).trim() + "\n" + String(username).trim() + "\n" + String(password) + "\n"
    saveProcess.command = Model.saveCommand(root.api)
    saveProcess.running = true
  }

  function forget() {
    if (root.saving || forgetProcess.running) return
    root.newSession()
    forgetProcess.command = Model.forgetCommand(root.api)
    forgetProcess.running = true
  }

  function checkAuth() {
    root.authState = "checking"
    if (authProcess.running) { root.authRecheck = true; return }
    authProcess.session = root.session
    authProcess.command = Model.authCommand(root.api)
    authProcess.running = true
  }

  function refresh() {
    if (!root.authenticated) { root.checkAuth(); return }
    if (entriesProcess.running) { root.refreshQueued = true; return }
    root.refreshQueued = false
    root.loading = true
    root.errorText = ""
    entriesProcess.generation = root.listGeneration
    entriesProcess.command = Model.entriesCommand(root.api, root.entryLimit, root.unreadOnly)
    entriesProcess.running = true
    autoRefresh.restart()
  }

  // A changed limit or filter makes any fetch in flight the wrong list.
  function listSettingsChanged() {
    root.listGeneration++
    if (root.authenticated) root.refresh()
  }
  onEntryLimitChanged: root.listSettingsChanged()
  onUnreadOnlyChanged: root.listSettingsChanged()

  function withoutPending(list) {
    var kept = []
    for (var i = 0; i < list.length; i++)
      if (!root.pending[list[i].id]) kept.push(list[i])
    return kept
  }

  // Marks a batch read and takes those rows out of the list straight away.
  function markRead(ids) {
    if (!root.authenticated) return
    var pending = Object.assign({}, root.pending)
    var fresh = []
    for (var i = 0; i < ids.length; i++) {
      if (pending[ids[i]]) continue
      pending[ids[i]] = true
      fresh.push(ids[i])
    }
    if (fresh.length === 0) return
    root.pending = pending
    root.entries = root.withoutPending(root.entries)
    root.total = Math.max(0, root.total - fresh.length)
    root.markQueue = root.markQueue.concat(fresh)
    root.flushMarks()
  }

  // Sends everything queued as one batch, unless a request is already out;
  // its completion flushes again.
  function flushMarks() {
    if (markProcess.running || root.markQueue.length === 0) return
    var ids = root.markQueue
    root.markQueue = []
    markProcess.session = root.session
    markProcess.ids = ids
    markProcess.command = Model.markReadCommand(root.api, ids)
    markProcess.running = true
  }

  // Only what is loaded right now: the batch is built from the listed rows,
  // never from the instance's wider unread count, so entries beyond the list
  // are left alone.
  function markAllRead() {
    var ids = []
    for (var i = 0; i < root.entries.length; i++)
      if (root.entries[i].unread) ids.push(root.entries[i].id)
    root.markRead(ids)
  }

  // Hands an entry to the account's save integration. The entry stays in the
  // list -- saving is not reading -- so the only feedback is the notice, which
  // clears itself after a few seconds.
  function saveEntry(id) {
    if (!root.authenticated || root.saveEntryBusy) return
    root.saveEntryBusy = true
    root.saveNotice = ""
    saveEntryProcess.session = root.session
    saveEntryProcess.command = Model.saveEntryCommand(root.api, id)
    saveEntryProcess.running = true
  }

  // A notice that asks for action stays up long enough to be read and acted on.
  // A plain confirmation that lands after every panel closed has nobody to
  // tell, so it is dropped; a sticky one waits for the next open.
  function noteSaved(message, ms, sticky) {
    if (!sticky && root.openPanels === 0) return
    root.saveNotice = message
    root.saveNoticeSticky = sticky === true
    saveNoticeTimer.interval = ms || 4000
    if (root.openPanels > 0) saveNoticeTimer.restart()
    else saveNoticeTimer.stop()
  }

  // Sign-in is checked once at load, so the refresh timer and the bar's
  // new-entry dot work before any panel has been opened.
  Component.onCompleted: root.checkAuth()

  // When the last IPC refresh went out. A hotkey held down or a script in a
  // loop would otherwise turn into one request per call; the panel's own "r"
  // is not throttled, since a person pressing it is already rate-limited.
  property double lastIpcRefresh: 0
  readonly property int ipcRefreshFloorMs: 10000

  // omarchy-shell anavarre.miniflux <method>. Every answer is a fixed word or
  // a small JSON object of counts and flags: no server address, username,
  // entry titles, error text or anything read from the credential store, so
  // nothing a script logs can leak the account.
  IpcHandler {
    target: "anavarre.miniflux"

    // "ok" when a fetch (or, signed out, a sign-in check) was started or
    // queued behind the one in flight; "throttled" within 10 s of the last.
    function refresh(): string {
      var now = Date.now()
      if (now - root.lastIpcRefresh < root.ipcRefreshFloorMs) return "throttled"
      root.lastIpcRefresh = now
      root.refresh()
      return "ok"
    }

    // Opens or closes the panel on the focused bar, through the host's own
    // toggle so it behaves like a click. "unavailable" when there is no live
    // bar widget to open (a third-party bar, or the widget not placed).
    function toggle(): string {
      var id = root.manifest && root.manifest.id ? String(root.manifest.id) : "anavarre.miniflux"
      var done = root.shell && typeof root.shell.toggle === "function" && root.shell.toggle(id, "{}")
      return done ? "ok" : "unavailable"
    }

    // {"auth":"unknown|checking|ok|error","loading":bool,"error":bool,
    //  "listed":n,"unread":n,"total":n,"new":bool}
    function status(): string {
      return JSON.stringify({
        auth: root.authState,
        loading: root.loading,
        error: root.errorText !== "" || root.authError !== "",
        listed: root.entries.length,
        unread: root.listedUnread,
        total: root.total,
        "new": root.hasNewEntries
      })
    }
  }

  // Keeps the list current in the background, so an open shows fresh entries
  // rather than starting a fetch you wait on. A manual refresh restarts it.
  Timer {
    id: autoRefresh
    interval: Math.max(root.refreshMin, root.refreshMinutes) * 60000
    repeat: true
    running: root.authenticated
    onTriggered: root.refresh()
  }

  Timer {
    id: saveNoticeTimer
    interval: 4000
    onTriggered: root.saveNotice = ""
  }

  Process {
    id: saveEntryProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: saveEntryStdout; waitForEnd: true }
    stderr: StdioCollector { id: saveEntryStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.saveEntryBusy = false
      if (saveEntryProcess.session !== root.session) return
      var response = Model.splitResponse(saveEntryStdout.text)
      if (exitCode === 0 && (response.status === 202 || response.status === 200 || response.status === 204)) {
        root.noteSaved("Saved.")
        return
      }
      root.errorText = Model.saveEntryMessage(saveEntryStderr.text, exitCode, response.status)
    }
  }

  Process {
    id: configProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: configStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 || configProcess.session !== root.session) return
      try {
        var config = Model.parseConfig(configStdout.text)
        root.storedServer = config.server
        root.storedUsername = config.username
        root.hasSecret = config.hasSecret
      } catch (e) {
        // Nothing stored yet — the empty form is the right thing to show.
      }
    }
  }

  Process {
    id: saveProcess
    property string payload: ""
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdinEnabled: true
    stdout: StdioCollector { id: saveStdout; waitForEnd: true }
    stderr: StdioCollector { id: saveStderr; waitForEnd: true }
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        root.authState = "error"
        root.authHint = ""
        root.authError = Model.saveMessage(saveStderr.text, exitCode)
        return
      }
      root.newSession()
      root.hasSecret = true
      var warning = Model.saveWarning(saveStdout.text)
      if (warning !== "") root.noteSaved(warning, 15000, true)
      root.signedIn()
      root.authState = "unknown"
      root.checkAuth()
    }
  }

  Process {
    id: forgetProcess
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stderr: StdioCollector { id: forgetStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // A refused store (exit 24) removed nothing, so the files and the
      // sign-in state stay as they were.
      if (exitCode !== 0) {
        root.authError = Model.errorMessage(forgetStderr.text, exitCode, 0)
        root.authHint = ""
        return
      }
      root.hasSecret = false
      root.storedServer = ""
      root.storedUsername = ""
      root.entries = []
      root.seenIds = null
      root.hasNewEntries = false
      root.total = 0
      root.account = ""
      root.authState = "unknown"
      root.authError = ""
      root.authHint = "Credentials removed."
      root.forgotten()
    }
  }

  Process {
    id: authProcess
    property int session: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: authStdout; waitForEnd: true }
    stderr: StdioCollector { id: authStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // Asked again while this one ran — its answer may predate a sign-in.
      if (root.authRecheck) {
        root.authRecheck = false
        Qt.callLater(root.checkAuth)
        return
      }
      if (authProcess.session !== root.session) return
      if (Model.needsSetup(exitCode)) {
        root.authState = "error"
        root.authError = ""
        root.authHint = Model.setupMessage(exitCode)
        root.loadConfig()
        return
      }
      var response = Model.splitResponse(authStdout.text)
      if (exitCode !== 0 || response.status !== 200) {
        root.authState = "error"
        root.authHint = ""
        root.authError = Model.errorMessage(authStderr.text, exitCode, response.status)
        root.loadConfig()
        return
      }
      try {
        root.account = Model.parseMe(response.body).username
      } catch (e) {
        root.account = ""
      }
      root.authState = "ok"
      root.clearAuthMessages()
      root.refresh()
    }
  }

  Process {
    id: entriesProcess
    property int generation: 0
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: entriesStdout; waitForEnd: true }
    stderr: StdioCollector { id: entriesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      // A newer refresh is waiting, or this one answers for settings or a
      // session that are gone: run the follow-up instead of showing it.
      if (root.refreshQueued || entriesProcess.generation !== root.listGeneration) {
        if (root.refreshQueued && root.authenticated) Qt.callLater(root.refresh)
        root.refreshQueued = false
        return
      }
      var response = Model.splitResponse(entriesStdout.text)
      if (response.status === 401 || response.status === 403) {
        root.authState = "error"
        root.authHint = ""
        root.authError = Model.errorMessage(entriesStderr.text, exitCode, response.status)
        return
      }
      if (exitCode !== 0 || response.status !== 200) {
        root.errorText = Model.errorMessage(entriesStderr.text, exitCode, response.status)
        return
      }
      try {
        var list = Model.parseEntries(response.body)
        root.noteEntries(list)
        root.entries = root.withoutPending(list)
        root.total = Math.max(0, Model.totalEntries(response.body) - (list.length - root.entries.length))
        root.errorText = ""
      } catch (e) {
        root.errorText = "Could not read the Miniflux response."
      }
    }
  }

  Process {
    id: markProcess
    property int session: 0
    property var ids: []
    running: false
    command: []
    clearEnvironment: true
    environment: Model.environment
    stdout: StdioCollector { id: markStdout; waitForEnd: true }
    stderr: StdioCollector { id: markStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var response = Model.splitResponse(markStdout.text)
      var ok = exitCode === 0 && (response.status === 204 || response.status === 200)
      if (markProcess.session !== root.session) return
      var pending = Object.assign({}, root.pending)
      for (var i = 0; i < markProcess.ids.length; i++) delete pending[markProcess.ids[i]]
      root.pending = pending
      markProcess.ids = []
      Qt.callLater(root.flushMarks)
      if (ok) {
        // Marking the list read can empty it while the instance still holds
        // unread entries the limit kept out. Pulling the next batch straight
        // away shows them without waiting for a manual "r".
        if (root.entries.length === 0 && root.total > 0) root.refresh()
        return
      }
      // The rows were taken out on the assumption this would work; refetching
      // is the honest way to put back whatever is actually still unread.
      root.errorText = Model.errorMessage(markStderr.text, exitCode, response.status)
      root.refresh()
    }
  }
}
