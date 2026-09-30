// State tests for Service.qml. Every Process is the fake in tests/qml/fakes:
// nothing runs, and each test finishes requests by hand, in whatever order it
// wants to check. Credentials and entries are fictional.
import QtQuick
import QtTest

TestCase {
  id: tc
  name: "Service"

  property var svc: null

  Component {
    id: serviceComponent
    // Loaded by URL so the service resolves Model.js and bin/ as it does
    // under the shell.
    Loader { source: Qt.resolvedUrl("../../../Service.qml") }
  }

  SignalSpy { id: signedInSpy; signalName: "signedIn" }
  SignalSpy { id: forgottenSpy; signalName: "forgotten" }

  function init() {
    var loader = createTemporaryObject(serviceComponent, tc)
    verify(loader.item, "Service.qml loads")
    svc = loader.item
    signedInSpy.clear()
    signedInSpy.target = svc
    forgottenSpy.clear()
    forgottenSpy.target = svc
  }

  // The process whose last command was `sub` (auth, entries, mark, ...).
  function proc(sub) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && typeof o.finish === "function" && o.command.length > 2 && o.command[2] === sub) return o
    }
    return null
  }

  function ipc() {
    for (var i = 0; i < svc.data.length; i++)
      if (svc.data[i] && svc.data[i].target === "anavarre.miniflux") return svc.data[i]
    return null
  }

  function me() { return JSON.stringify({ id: 1, username: "ann" }) + "\n200\n" }

  function listing(ids, total) {
    var entries = []
    for (var i = 0; i < ids.length; i++)
      entries.push({ id: ids[i], title: "Entry " + ids[i], status: "unread" })
    return JSON.stringify({ total: total === undefined ? ids.length : total, entries: entries }) + "\n200\n"
  }

  function ids() {
    var out = []
    for (var i = 0; i < svc.entries.length; i++) out.push(svc.entries[i].id)
    return out
  }

  // Signed in, with `list` as the first fetch.
  function signedIn(list, total) {
    proc("auth").finish(0, me(), "")
    compare(svc.authState, "ok")
    proc("entries").finish(0, listing(list, total), "")
    compare(svc.loading, false)
  }

  function test_startupChecksSignIn() {
    compare(svc.authState, "checking")
    var auth = proc("auth")
    verify(auth.running)
    auth.finish(0, me(), "")
    compare(svc.authState, "ok")
    compare(svc.account, "ann")
    var entries = proc("entries")
    verify(entries.running)
    compare(svc.loading, true)
    compare(entries.command.slice(3), ["10", "unread"])
    entries.finish(0, listing([1, 2]), "")
    compare(ids(), [1, 2])
    compare(svc.total, 2)
  }

  // A middle-click or IPC refresh while signed out re-checks sign-in instead.
  function test_refreshWhileSignedOutRechecks() {
    proc("auth").finish(11, "", "")
    compare(svc.authState, "error")
    compare(svc.authHint, "Enter your Miniflux username.")
    verify(proc("config").running, "loads the stored config for the form")
    svc.refresh()
    compare(svc.authState, "checking")
    compare(proc("auth").starts, 2)
    compare(proc("entries"), null, "nothing is fetched signed out")
  }

  function test_configFillsFormAndStoreDir() {
    proc("auth").finish(11, "", "")
    proc("config").finish(0, JSON.stringify({ server: "https://rss.example.test", username: "ann",
      hasSecret: true, store: "~/.config/omarchy/miniflux" }) + "\n", "")
    compare(svc.storedServer, "https://rss.example.test")
    compare(svc.storedUsername, "ann")
    compare(svc.hasSecret, true)
    compare(svc.storeDir, "~/.config/omarchy/miniflux")
  }

  function test_checkDuringCheckRunsOnceAfter() {
    var auth = proc("auth")
    svc.checkAuth()
    svc.checkAuth()
    compare(auth.starts, 1)
    auth.finish(0, me(), "")
    compare(svc.authState, "checking", "the stale answer is dropped")
    tryCompare(auth, "starts", 2)
    auth.finish(0, me(), "")
    compare(svc.authState, "ok")
  }

  function test_refreshesCoalesce() {
    proc("auth").finish(0, me(), "")
    var entries = proc("entries")
    svc.refresh()
    svc.refresh()
    svc.refresh()
    compare(entries.starts, 1)
    compare(svc.refreshQueued, true)
    entries.finish(0, listing([1]), "")
    compare(ids(), [], "the superseded answer is not shown")
    tryCompare(entries, "starts", 2)
    wait(20)
    compare(entries.starts, 2, "three clicks make one follow-up")
    entries.finish(0, listing([1, 2]), "")
    compare(ids(), [1, 2])
  }

  function test_changedLimitDropsOldFetch() {
    proc("auth").finish(0, me(), "")
    var entries = proc("entries")
    svc.entryLimit = 5
    entries.finish(0, listing([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), "")
    compare(ids(), [])
    tryCompare(entries, "starts", 2)
    compare(entries.command[3], "5")
    entries.finish(0, listing([1, 2, 3, 4, 5]), "")
    compare(ids(), [1, 2, 3, 4, 5])
  }

  function test_marksQueueBehindTheOneInFlight() {
    signedIn([1, 2, 3], 3)
    svc.markRead([1])
    compare(ids(), [2, 3])
    compare(svc.total, 2)
    var mark = proc("mark")
    compare(mark.command.slice(3), ["1"])
    svc.markRead([2])
    svc.markRead([2])
    compare(mark.starts, 1)
    compare(svc.markQueue, [2])
    compare(ids(), [3])

    // A fetch landing now still has 1 and 2 unread; they stay out.
    svc.refresh()
    proc("entries").finish(0, listing([1, 2, 3, 4], 4), "")
    compare(ids(), [3, 4])
    compare(svc.total, 2)

    mark.finish(0, "\n204\n", "")
    tryCompare(mark, "starts", 2)
    compare(mark.command.slice(3), ["2"])
    mark.finish(0, "\n204\n", "")
    compare(svc.pending, ({}))
    compare(svc.errorText, "")
  }

  function test_failedMarkRefetches() {
    signedIn([1, 2], 2)
    svc.markRead([1])
    var entries = proc("entries")
    proc("mark").finish(22, "\n500\n", "")
    verify(svc.errorText !== "")
    compare(entries.starts, 2, "refetches to put the row back")
    entries.finish(0, listing([1, 2]), "")
    compare(ids(), [1, 2])
    verify(svc.errorText !== "", "the failure outlasts the refetch")
    svc.refresh()
    compare(svc.errorText, "", "and clears on the next refresh")
  }

  function test_markAllOnlyTakesListedAndRefills() {
    signedIn([1, 2], 5)
    svc.markAllRead()
    compare(proc("mark").command.slice(3), ["1", "2"])
    compare(ids(), [])
    compare(svc.total, 3)
    proc("mark").finish(0, "\n204\n", "")
    compare(proc("entries").starts, 2, "pulls the next batch")
  }

  function test_markAfterForgetIsIgnored() {
    signedIn([1, 2], 2)
    svc.markRead([1])
    var mark = proc("mark")
    svc.forget()
    proc("forget").finish(0, "", "")
    compare(forgottenSpy.count, 1)
    compare(svc.authState, "unknown")
    compare(ids(), [])
    compare(svc.authHint, "Credentials removed.")
    mark.finish(22, "\n500\n", "")
    compare(svc.errorText, "", "the old session's failure is not reported")
    compare(proc("entries").starts, 1, "and does not refetch")
  }

  function test_signInSendsSecretOnStdinThenRechecks() {
    proc("auth").finish(10, "", "")
    var session = svc.session
    svc.signIn("  https://rss.example.test ", " ann ", "pw")
    compare(svc.saving, true)
    var save = proc("save")
    compare(save.written, "https://rss.example.test\nann\npw\n")
    compare(save.command.indexOf("pw"), -1, "the password never rides in argv")
    compare(save.stdinEnabled, false)
    save.finish(0, "", "")
    compare(svc.saving, false)
    compare(signedInSpy.count, 1)
    compare(svc.session, session + 1)
    compare(svc.authState, "checking")
    compare(proc("auth").starts, 2)
  }

  function test_failedSignInKeepsState() {
    proc("auth").finish(10, "", "")
    svc.signIn("https://rss.example.test", "ann", "wrong")
    proc("save").finish(20, "", "")
    compare(svc.authState, "error")
    verify(svc.authError !== "")
    compare(signedInSpy.count, 0)
  }

  function test_newEntriesDot() {
    signedIn([1, 2], 2)
    compare(svc.hasNewEntries, false, "the first fetch is the baseline")
    svc.refresh()
    proc("entries").finish(0, listing([1, 2]), "")
    compare(svc.hasNewEntries, false)
    svc.refresh()
    proc("entries").finish(0, listing([3, 1, 2]), "")
    compare(svc.hasNewEntries, true)
    svc.panelOpened()
    compare(svc.hasNewEntries, false)
    svc.refresh()
    proc("entries").finish(0, listing([4, 3, 1, 2]), "")
    compare(svc.hasNewEntries, false, "not while a panel shows the list")
    svc.panelClosed()
  }

  function test_closingLastPanelDropsPlainNotice() {
    svc.panelOpened()
    svc.panelOpened()
    svc.noteSaved("Done.")
    compare(svc.saveNotice, "Done.")
    svc.panelClosed()
    compare(svc.saveNotice, "Done.", "another monitor still shows it")
    svc.panelClosed()
    compare(svc.saveNotice, "")
    compare(svc.openPanels, 0)
    svc.panelClosed()
    compare(svc.openPanels, 0, "never below zero")

    svc.noteSaved("Done.")
    compare(svc.saveNotice, "", "nobody to tell once every panel closed")
  }

  function test_savedEntriesAreMarked() {
    signedIn([1, 2], 2)
    svc.saveEntry(1)
    compare(svc.savingId, 1)
    var save = proc("save-entry")
    compare(save.command.slice(3), ["1"])
    svc.saveEntry(2)
    compare(save.starts, 1, "one save at a time")
    save.finish(0, "\n202\n", "")
    compare(svc.savingId, 0)
    compare(svc.savedIds, { 1: true })
    compare(svc.saveNotice, "", "the bookmark is the confirmation")

    svc.saveEntry(1)
    compare(save.starts, 1, "a saved entry is not sent twice")
    svc.saveEntry(2)
    save.finish(0, "\n403\n", "")
    compare(svc.savedIds, { 1: true }, "a refused save is not marked")
    compare(svc.errorText, "Miniflux has no save integration enabled for this account.")

    svc.refresh()
    proc("entries").finish(0, listing([1, 3]), "")
    compare(svc.savedIds, { 1: true })
    svc.refresh()
    proc("entries").finish(0, listing([3]), "")
    compare(svc.savedIds, ({}), "entries no longer listed are dropped")
  }

  function test_saveAfterForgetIsIgnored() {
    signedIn([1], 1)
    svc.saveEntry(1)
    svc.forget()
    proc("forget").finish(0, "", "")
    proc("save-entry").finish(0, "\n202\n", "")
    compare(svc.savedIds, ({}))
    compare(svc.saveEntryBusy, false)
  }

  function test_stickyNoticeOutlastsClose() {
    svc.panelOpened()
    svc.noteSaved("Revoke the old key.", 15000, true)
    svc.panelClosed()
    compare(svc.saveNotice, "Revoke the old key.")
    svc.panelOpened()
    compare(svc.saveNotice, "Revoke the old key.")
    svc.panelClosed()
  }

  function test_ipcRefreshIsThrottled() {
    var h = ipc()
    verify(h)
    compare(h.refresh(), "ok")
    compare(h.refresh(), "throttled")
    compare(proc("auth").starts, 1, "the throttled call started nothing")
    svc.lastIpcRefresh = Date.now() - svc.ipcRefreshFloorMs
    compare(h.refresh(), "ok")
  }

  function test_ipcToggle() {
    var h = ipc()
    compare(h.toggle(), "unavailable")
    var asked = []
    svc.shell = { toggle: function(id, payload) { asked.push([id, payload]); return true } }
    compare(h.toggle(), "ok")
    compare(asked, [["anavarre.miniflux", "{}"]])
  }

  function test_ipcStatusCarriesNoAccountData() {
    svc.storedServer = "https://rss.example.test"
    svc.storedUsername = "ann"
    signedIn([1, 2], 7)
    var raw = ipc().status()
    compare(JSON.parse(raw), { auth: "ok", loading: false, error: false, listed: 2, unread: 2, total: 7, "new": false })
    verify(raw.indexOf("example") < 0 && raw.indexOf("ann") < 0 && raw.indexOf("Entry") < 0)
  }
}
