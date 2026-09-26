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
  property bool saveEntryBusy: false
  property var entries: []
  property int total: 0

  // Entries being marked read are dropped from the list as soon as the
  // request goes out — the round trip is the slow part, and a row that lingers
  // invites a second click on something already gone. A failure puts the whole
  // list back by refetching.
  property var pending: []

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
  }

  function panelClosed() {
    root.openPanels = Math.max(0, root.openPanels - 1)
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
    configProcess.command = Model.configCommand()
    configProcess.running = true
  }

  function signIn(server, username, password) {
    if (root.saving) return
    root.saving = true
    root.clearAuthMessages()
    saveProcess.payload = String(server).trim() + "\n" + String(username).trim() + "\n" + String(password) + "\n"
    saveProcess.command = Model.saveCommand()
    saveProcess.running = true
  }

  function forget() {
    forgetProcess.command = Model.forgetCommand()
    forgetProcess.running = true
  }

  function checkAuth() {
    if (root.authState === "checking") return
    root.authState = "checking"
    authProcess.command = Model.authCommand()
    authProcess.running = true
  }

  function refresh() {
    if (!root.authenticated) { root.checkAuth(); return }
    if (root.loading) return
    root.loading = true
    root.errorText = ""
    entriesProcess.command = Model.entriesCommand(root.entryLimit, root.unreadOnly)
    entriesProcess.running = true
    autoRefresh.restart()
  }

  // Marks a batch read and takes those rows out of the list straight away.
  function markRead(ids) {
    if (!root.authenticated || ids.length === 0) return
    var gone = {}
    for (var i = 0; i < ids.length; i++) gone[ids[i]] = true
    var kept = []
    for (var j = 0; j < root.entries.length; j++) {
      if (!gone[root.entries[j].id]) kept.push(root.entries[j])
    }
    root.entries = kept
    root.total = Math.max(0, root.total - ids.length)
    root.pending = ids
    markProcess.command = Model.markReadCommand(ids)
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
    saveEntryProcess.command = Model.saveEntryCommand(id)
    saveEntryProcess.running = true
  }

  // A notice that asks for action stays up long enough to be read and acted on.
  function noteSaved(message, ms) {
    root.saveNotice = message
    saveNoticeTimer.interval = ms || 4000
    saveNoticeTimer.restart()
  }

  // Sign-in is checked once at load, so the refresh timer and the bar's
  // new-entry dot work before any panel has been opened.
  Component.onCompleted: root.checkAuth()

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
    running: false
    command: []
    stdout: StdioCollector { id: saveEntryStdout; waitForEnd: true }
    stderr: StdioCollector { id: saveEntryStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.saveEntryBusy = false
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
    running: false
    command: []
    stdout: StdioCollector { id: configStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
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
      root.hasSecret = true
      var warning = Model.saveWarning(saveStdout.text)
      if (warning !== "") root.noteSaved(warning, 15000)
      root.signedIn()
      root.authState = "unknown"
      root.checkAuth()
    }
  }

  Process {
    id: forgetProcess
    running: false
    command: []
    onExited: {
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
    running: false
    command: []
    stdout: StdioCollector { id: authStdout; waitForEnd: true }
    stderr: StdioCollector { id: authStderr; waitForEnd: true }
    onExited: function(exitCode) {
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
    running: false
    command: []
    stdout: StdioCollector { id: entriesStdout; waitForEnd: true }
    stderr: StdioCollector { id: entriesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
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
        root.entries = Model.parseEntries(response.body)
        root.noteEntries(root.entries)
        root.total = Model.totalEntries(response.body)
        root.errorText = ""
      } catch (e) {
        root.errorText = "Could not read the Miniflux response."
      }
    }
  }

  Process {
    id: markProcess
    running: false
    command: []
    stdout: StdioCollector { id: markStdout; waitForEnd: true }
    stderr: StdioCollector { id: markStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var response = Model.splitResponse(markStdout.text)
      var ok = exitCode === 0 && (response.status === 204 || response.status === 200)
      root.pending = []
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
