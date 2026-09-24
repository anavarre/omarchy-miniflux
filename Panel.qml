import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "anavarre.miniflux"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // Pushed in by the bar widget, which is the only side the shell injects
  // user settings into.
  property int entryLimit: 10
  // 1 up to the API's own ceiling, so the list can be as short or as long as
  // the user wants it.
  readonly property int entryLimitMin: 1
  readonly property int entryLimitMax: 100
  property bool unreadOnly: true
  // Minutes between automatic refreshes. Injected from the stored setting and
  // written back by the Settings section; always one of the allowed steps.
  property int refreshMinutes: 30
  // 30 minutes up to a day, so the interval can never hammer the instance.
  readonly property var refreshChoices: [30, 60, 120, 180, 360, 720, 1440]
  readonly property int refreshMin: refreshChoices[0]
  readonly property int refreshMax: refreshChoices[refreshChoices.length - 1]

  // Text size is offered as named sizes rather than pixel values — the user
  // picks how big the panel reads, and every font size in it is scaled by the
  // matching factor.
  // Whether a refresh that brings in unseen entries lights up the bar icon.
  property bool newEntryIndicator: true

  property string textSize: "medium"
  readonly property var textSizes: [
    { value: "small", label: "Small", scale: 0.85 },
    { value: "medium", label: "Medium", scale: 1.0 },
    { value: "large", label: "Large", scale: 1.2 },
    { value: "xlarge", label: "Extra large", scale: 1.45 }
  ]
  readonly property real textScale: {
    for (var i = 0; i < root.textSizes.length; i++)
      if (root.textSizes[i].value === root.textSize) return root.textSizes[i].scale
    return 1.0
  }

  // Every font size in this panel goes through here, so one setting moves all
  // of them together.
  function fs(size) { return Math.round(size * root.textScale) }

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

  // The sign-in form. It opens by itself when there is nothing stored or what
  // is stored no longer works, and on demand from "Account".
  property bool configuring: false
  property bool saving: false
  property bool hasSecret: false
  readonly property bool showSignIn: root.configuring || root.authState === "unknown"
    || (!root.authenticated && (root.authError !== "" || root.authHint !== ""))
  readonly property bool showSettings: root.settingsOpen && !root.showSignIn

  // The Settings section, reached from the footer. It replaces the list while
  // it is up, the way the sign-in form does.
  property bool settingsOpen: false

  // The shortcuts cheat sheet, opened with "?" or the footer's question mark.
  // It floats over whatever section is up rather than replacing it, so you
  // can read a binding without losing your place in the list.
  property bool shortcutsOpen: false
  readonly property var shortcuts: [
    { keys: "j / k", what: "Move the selection" },
    { keys: "Enter", what: "Open the selected entry" },
    { keys: "x", what: "Mark the selected entry read" },
    { keys: "a", what: "Mark the listed entries read" },
    { keys: "r", what: "Refresh now" },
    { keys: "s", what: "Save the selected entry" },
    { keys: ",", what: "Settings" },
    { keys: "c", what: "Account / sign in" },
    { keys: "Tab", what: "Switch to the next panel" },
    { keys: "?", what: "Show or hide this list" },
    { keys: "Esc", what: "Close" }
  ]

  property bool loading: false
  property string errorText: ""
  // Transient confirmation for the save shortcut, shown under the header.
  property string saveNotice: ""
  property bool saveEntryBusy: false
  property var entries: []
  property int total: 0
  property int selected: -1

  // Entries being marked read are dropped from the list as soon as the
  // request goes out — the round trip is the slow part, and a row that lingers
  // invites a second click on something already gone. A failure puts the whole
  // list back by refetching.
  property var pending: []

  // Set when a background refresh turns up entry ids that were not in the
  // previous list. The bar widget reads it to paint its dot; opening the panel
  // is what clears it, since by then you have seen them.
  property bool hasNewEntries: false
  // Ids from the last fetch, rebuilt each time so the map cannot grow without
  // bound. Null until the first fetch lands — that one only sets the baseline,
  // so signing in does not immediately claim everything is new.
  property var seenIds: null

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
    if (fresh && !root.opened) root.hasNewEntries = true
  }

  function clearNewEntries() {
    root.hasNewEntries = false
    var seen = {}
    for (var i = 0; i < root.entries.length; i++) seen[root.entries[i].id] = true
    root.seenIds = seen
  }

  function setNewEntryIndicator(on) {
    if (on === root.newEntryIndicator) return
    root.newEntryIndicator = on
    if (!on) root.hasNewEntries = false
    if (root.hostWidget && typeof root.hostWidget.saveNewEntryIndicator === "function")
      root.hostWidget.saveNewEntryIndicator(on)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The card grows with the text, so a larger size means fewer wrapped titles
  // rather than the same column set in bigger type.
  readonly property real cardWidth: panel.fittedContentWidth(Style.space(Math.round(460 * root.textScale)))
  // The list gets whatever the screen leaves once the header, the footer and
  // the card's own padding are taken out.
  readonly property real maxListHeight: Math.max(Style.space(120),
    panel.cappedContentHeight(Style.space(560)) - panel.verticalContentInset - Style.space(80))

  function open() { root.controller.show() }
  function close() { root.controller.hide() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function loadConfig() {
    configProcess.command = Model.configCommand()
    configProcess.running = true
  }

  function openSignIn() {
    root.settingsOpen = false
    root.configuring = true
    root.authError = ""
    root.authHint = ""
    root.loadConfig()
    Qt.callLater(function() { serverField.forceActiveFocus() })
  }

  function saveSignIn() {
    if (root.saving) return
    root.saving = true
    root.authError = ""
    root.authHint = ""
    saveProcess.payload = serverField.text.trim() + "\n" + userField.text.trim() + "\n" + passField.text + "\n"
    saveProcess.command = Model.saveCommand()
    saveProcess.running = true
  }

  function cancelSignIn() {
    if (!root.authenticated) { root.close(); return }
    root.configuring = false
    passField.text = ""
    root.authError = ""
    root.authHint = ""
  }

  function forgetSignIn() {
    forgetProcess.command = Model.forgetCommand()
    forgetProcess.running = true
  }

  // Snaps whatever comes in to the nearest allowed choice, so a stored value
  // from an older version still lands on something valid.
  function setRefreshMinutes(minutes) {
    var wanted = Number(minutes)
    if (!isFinite(wanted)) wanted = root.refreshMin
    var n = root.refreshChoices[0]
    for (var i = 1; i < root.refreshChoices.length; i++) {
      if (Math.abs(root.refreshChoices[i] - wanted) < Math.abs(n - wanted))
        n = root.refreshChoices[i]
    }
    if (n === root.refreshMinutes) return
    root.refreshMinutes = n
    if (root.hostWidget && typeof root.hostWidget.saveRefreshMinutes === "function")
      root.hostWidget.saveRefreshMinutes(n)
  }

  // Written back through the widget like the other panel-side settings, and
  // the list is refetched so the new count is visible straight away.
  function setEntryLimit(value) {
    var n = Math.round(Number(value))
    if (!isFinite(n)) return
    n = Math.max(root.entryLimitMin, Math.min(root.entryLimitMax, n))
    if (n === root.entryLimit) return
    root.entryLimit = n
    if (root.hostWidget && typeof root.hostWidget.saveEntryLimit === "function")
      root.hostWidget.saveEntryLimit(n)
    if (root.authenticated) root.refresh()
  }

  // One at a time up to ten, then in tens — a short list is tuned precisely,
  // a long one does not need forty clicks.
  function stepEntryLimit(delta) {
    var step = (delta > 0 ? root.entryLimit >= 10 : root.entryLimit > 10) ? 10 : 1
    var next = root.entryLimit + delta * step
    if (step === 10) next = Math.round(next / 10) * 10
    root.setEntryLimit(next)
  }

  function stepRefreshMinutes(delta) {
    var i = root.refreshChoices.indexOf(root.refreshMinutes)
    if (i < 0) { root.setRefreshMinutes(root.refreshMinutes); return }
    i = Math.max(0, Math.min(root.refreshChoices.length - 1, i + delta))
    root.setRefreshMinutes(root.refreshChoices[i])
  }

  function setTextSize(value) {
    var next = String(value || "")
    var known = false
    for (var i = 0; i < root.textSizes.length; i++)
      if (root.textSizes[i].value === next) known = true
    if (!known || next === root.textSize) return
    root.textSize = next
    if (root.hostWidget && typeof root.hostWidget.saveTextSize === "function")
      root.hostWidget.saveTextSize(next)
  }

  readonly property int textSizeIndex: {
    for (var i = 0; i < root.textSizes.length; i++)
      if (root.textSizes[i].value === root.textSize) return i
    return 1
  }

  readonly property string textSizeLabel: root.textSizes[root.textSizeIndex].label

  function stepTextSize(delta) {
    var i = Math.max(0, Math.min(root.textSizes.length - 1, root.textSizeIndex + delta))
    root.setTextSize(root.textSizes[i].value)
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

  function openEntry(index) {
    if (index < 0 || index >= root.entries.length) return
    var entry = root.entries[index]
    if (entry.url === "") return
    Qt.openUrlExternally(entry.url)
    root.close()
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
    root.selected = Math.min(root.selected, root.entries.length - 1)
    root.pending = ids
    markProcess.command = Model.markReadCommand(ids)
    markProcess.running = true
  }

  function markSelectedRead() {
    if (root.selected < 0 || root.selected >= root.entries.length) return
    root.markRead([root.entries[root.selected].id])
  }

  // Only what is loaded in the panel right now: the batch is built from the
  // rows on screen, never from the instance's wider unread count, so entries
  // beyond the list are left alone.
  function markAllRead() {
    var ids = []
    for (var i = 0; i < root.entries.length; i++)
      if (root.entries[i].unread) ids.push(root.entries[i].id)
    root.markRead(ids)
  }

  readonly property int listedUnread: {
    var n = 0
    for (var i = 0; i < root.entries.length; i++) if (root.entries[i].unread) n++
    return n
  }

  // Hands the selected entry to the account's save integration. The entry
  // stays in the list -- saving is not reading -- so the only feedback is the
  // note under the header, which clears itself after a few seconds.
  function saveSelected() {
    if (!root.authenticated) return
    if (root.selected < 0 || root.selected >= root.entries.length) return
    if (root.saveEntryBusy) return
    root.saveEntryBusy = true
    root.saveNotice = ""
    saveEntryProcess.command = Model.saveEntryCommand(root.entries[root.selected].id)
    saveEntryProcess.running = true
  }

  function noteSaved(message) {
    root.saveNotice = message
    saveNoticeTimer.restart()
  }

  function moveSelection(delta) {
    if (root.entries.length === 0) { root.selected = -1; return }
    var next = root.selected + delta
    if (next < 0) next = root.entries.length - 1
    else if (next >= root.entries.length) next = 0
    root.selected = next
    listView.revealSelected()
  }

  // The first open has nothing stored yet, so it lands on the sign-in form;
  // every later open refetches, because a feed list read an hour ago is stale.
  onOpenedChanged: {
    if (!opened) return
    root.clearNewEntries()
    root.selected = -1
    root.settingsOpen = false
    if (root.authenticated) root.refresh()
    else if (!root.configuring) root.checkAuth()
    if (root.showSignIn) Qt.callLater(function() { serverField.forceActiveFocus() })
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
        if (serverField.text === "") serverField.text = config.server
        if (userField.text === "") userField.text = config.username
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
    stdout: StdioCollector { waitForEnd: true }
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
      passField.text = ""
      root.hasSecret = true
      root.configuring = false
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
      root.entries = []
      root.seenIds = null
      root.hasNewEntries = false
      root.total = 0
      root.account = ""
      root.configuring = true
      root.authState = "unknown"
      root.authError = ""
      root.authHint = "Credentials removed."
      passField.text = ""
      Qt.callLater(function() { serverField.forceActiveFocus() })
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
        Qt.callLater(function() { serverField.forceActiveFocus() })
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
      root.authError = ""
      root.authHint = ""
      root.configuring = false
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
        root.selected = -1
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: root.showSignIn ? serverField : keys
    contentWidth: root.cardWidth
    // The cheat sheet floats over the content, so the panel still has to be
    // tall enough to hold it -- otherwise a short list leaves it overflowing
    // past the background.
    contentHeight: panel.fittedContentHeight(Math.max(content.implicitHeight,
      root.shortcutsOpen ? shortcutsSheet.implicitHeight : 0))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // The sign-in form owns the keyboard while it is up, so typing a
      // password doesn't drive the list underneath it.
      blocked: root.showSignIn
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onActivateRequested: root.openEntry(root.selected)
      onCloseRequested: {
        if (root.shortcutsOpen) root.shortcutsOpen = false
        else if (root.settingsOpen) root.settingsOpen = false
        else root.close()
      }
      onDeleteRequested: root.markSelectedRead()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "a") root.markAllRead()
        else if (text === "c") root.openSignIn()
        else if (text === "s") root.saveSelected()
        else if (text === ",") root.settingsOpen = !root.settingsOpen
        else if (text === "?") root.shortcutsOpen = !root.shortcutsOpen
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ------------------------------------------------------ sign-in form
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.showSignIn

          Text {
            width: parent.width
            text: "Sign in to Miniflux"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.subtitle)
            font.bold: true
          }

          Text {
            width: parent.width
            visible: root.authHint !== "" && root.authError === ""
            text: root.authHint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.authError !== ""
            text: root.authError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }

          TextField {
            id: serverField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.body)
            placeholderText: "miniflux.example.org"
            onAccepted: userField.forceActiveFocus()
            Keys.onEscapePressed: root.cancelSignIn()
          }

          TextField {
            id: userField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.body)
            placeholderText: "Username"
            onAccepted: passField.forceActiveFocus()
            Keys.onEscapePressed: root.cancelSignIn()
          }

          TextField {
            id: passField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.body)
            password: true
            placeholderText: "Password"
            onAccepted: root.saveSignIn()
            Keys.onEscapePressed: root.cancelSignIn()
          }

          Text {
            width: parent.width
            text: "The password is used once, to mint an API key that is stored instead. "
                + "Instances older than 2.2.9 keep the password in ~/.config/omarchy/miniflux, readable only by you."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.caption)
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: root.saving ? "Signing in…" : "Sign in"
              enabled: !root.saving
              foreground: root.foreground
              fontSize: root.fs(Style.font.body)
              bordered: true
              onClicked: root.saveSignIn()
            }

            Button {
              visible: root.authenticated
              text: "Cancel"
              foreground: root.foreground
              fontSize: root.fs(Style.font.body)
              onClicked: root.cancelSignIn()
            }

            Button {
              visible: root.hasSecret
              text: "Forget credentials"
              foreground: root.foreground
              fontSize: root.fs(Style.font.body)
              onClicked: root.forgetSignIn()
            }
          }
        }

        // ---------------------------------------------------------- the list
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.showSignIn && !root.showSettings

          Item {
            width: parent.width
            height: Math.max(heading.implicitHeight, headingMeta.implicitHeight)

            Text {
              id: heading
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.unreadOnly ? "Unread" : "Latest"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.subtitle)
              font.bold: true
            }

            Text {
              id: headingMeta
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (root.loading) return "Fetching…"
                if (root.entries.length === 0) return ""
                return root.entries.length + " of " + Math.max(root.total, root.entries.length)
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.caption)
              elide: Text.ElideRight
            }
          }

          Text {
            width: parent.width
            visible: root.saveNotice !== "" && root.errorText === ""
            text: root.saveNotice
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.errorText !== ""
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: !root.loading && root.errorText === "" && root.entries.length === 0
            text: root.unreadOnly ? "Nothing unread." : "No entries."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.body)
          }

          // Takes exactly the height its rows need, and only scrolls — keeping
          // the keyboard selection in view — once they outgrow the screen.
          Flickable {
            id: listView
            width: parent.width
            height: Math.min(list.implicitHeight, root.maxListHeight)
            contentHeight: list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            function revealSelected() {
              if (root.selected < 0 || root.selected >= list.children.length) return
              var item = list.children[root.selected]
              if (item.y < contentY) contentY = item.y
              else if (item.y + item.height > contentY + height) contentY = item.y + item.height - height
            }

            Column {
              id: list
              width: listView.width
              spacing: Style.space(2)

              Repeater {
                model: root.entries

                Rectangle {
                  required property int index
                  required property var modelData

                  width: parent.width
                  height: row.implicitHeight + Style.space(8)
                  radius: Style.space(4)
                  color: index === root.selected || rowHover.hovered
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                    : "transparent"

                  HoverHandler { id: rowHover }

                  Row {
                    id: row
                    x: Style.space(6)
                    y: Style.space(4)
                    width: parent.width - Style.space(12)
                    spacing: Style.space(6)

                    // The title is the entry: it carries the link, so the
                    // whole text block is what you press to read it.
                    Column {
                      width: parent.width - markButton.width - Style.space(6)
                      spacing: Style.space(2)

                      HoverHandler {
                        id: titleHover
                        cursorShape: Qt.PointingHandCursor
                      }

                      TapHandler {
                        onTapped: {
                          root.selected = index
                          root.openEntry(index)
                        }
                      }

                      Text {
                        width: parent.width
                        text: Model.decodeTitle(modelData.title)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: root.fs(Style.font.body)
                        font.underline: titleHover.hovered
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: [modelData.feed, Model.formatAge(modelData.published)]
                          .filter(function(v) { return v !== "" }).join(" · ")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: root.fs(Style.font.caption)
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      id: markButton
                      anchors.verticalCenter: parent.verticalCenter
                      // nf-fa-check (U+F00C)
                      iconText: ""
                      tooltipText: "Mark as read"
                      foreground: root.dim
                      hoverColor: root.foreground
                      fontSize: root.fs(Style.font.bodySmall)
                      onClicked: root.markRead([modelData.id])
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Math.max(footerActions.implicitHeight, helpButton.implicitHeight)

          Row {
            id: footerActions
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Refresh"
              enabled: !root.loading
              foreground: root.foreground
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.refresh()
            }

            Button {
              text: "Mark as read"
              enabled: root.listedUnread > 0
              foreground: root.foreground
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.markAllRead()
            }

            Button {
              text: "Settings"
              foreground: root.dim
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.settingsOpen = true
            }

            Button {
              text: "Account"
              foreground: root.dim
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.openSignIn()
            }
          }

            PanelActionButton {
              id: helpButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-fa-question_circle (U+F059)
              iconText: ""
              tooltipText: "Keyboard shortcuts (?)"
              foreground: root.shortcutsOpen ? root.foreground : root.dim
              hoverColor: root.foreground
              fontSize: root.fs(Style.font.body)
              onClicked: root.shortcutsOpen = !root.shortcutsOpen
            }
          }
        }

        // ------------------------------------------------------- settings
        Column {
          id: settingsColumn
          width: parent.width
          spacing: Style.space(8)
          visible: root.showSettings

          // Every minus/plus row shares one value width — the widest value
          // across the rows — so the buttons line up in a single column
          // whatever the text size, with each value centred between them.
          readonly property real stepperValueWidth: Math.max(
            Style.space(Math.round(70 * root.textScale)),
            countValue.contentWidth,
            intervalValue.contentWidth,
            textSizeValue.contentWidth)

          // The minus/plus buttons set the height of every stepper row
          // (PanelActionButton.size), so the switch matches it and the
          // on/off row sits at exactly the same height as the others.
          readonly property real controlHeight: Math.max(
            Style.space(22),
            root.fs(Style.font.bodySmall) + Style.spacing.sm * 2)

          Text {
            width: parent.width
            text: "Settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.subtitle)
            font.bold: true
          }

          Item {
            width: parent.width
            height: Math.max(countCaption.implicitHeight, countControls.implicitHeight)

            Text {
              id: countCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              // Yields to the stepper rather than sliding under it.
              width: parent.width - countControls.width - Style.space(8)
              text: "Entries to show"
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.body)
            }

            Row {
              id: countControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-minus (U+F068)
                iconText: "\uf068"
                tooltipText: "Fewer"
                enabled: root.entryLimit > root.entryLimitMin
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepEntryLimit(-1)
              }

              Text {
                id: countValue
                anchors.verticalCenter: parent.verticalCenter
                width: settingsColumn.stepperValueWidth
                horizontalAlignment: Text.AlignHCenter
                text: root.entryLimit === 1 ? "1 entry" : root.entryLimit + " entries"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-plus (U+F067)
                iconText: "\uf067"
                tooltipText: "More"
                enabled: root.entryLimit < root.entryLimitMax
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepEntryLimit(1)
              }
            }
          }

          Item {
            width: parent.width
            height: Math.max(intervalLabel.implicitHeight, intervalControls.implicitHeight)

            Text {
              id: intervalLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              // Yields to the stepper rather than sliding under it.
              width: parent.width - intervalControls.width - Style.space(8)
              text: "Refresh every"
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.body)
            }

            Row {
              id: intervalControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-minus (U+F068)
                iconText: "\uf068"
                tooltipText: "Less often"
                enabled: root.refreshMinutes > root.refreshMin
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepRefreshMinutes(-1)
              }

              Text {
                id: intervalValue
                anchors.verticalCenter: parent.verticalCenter
                width: settingsColumn.stepperValueWidth
                horizontalAlignment: Text.AlignHCenter
                text: root.refreshMinutes < 60
                  ? root.refreshMinutes + " min"
                  : (root.refreshMinutes / 60) + (root.refreshMinutes === 60 ? " hour" : " hours")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-plus (U+F067)
                iconText: "\uf067"
                tooltipText: "More often"
                enabled: root.refreshMinutes < root.refreshMax
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepRefreshMinutes(1)
              }
            }
          }

          // Same minus/plus control as the refresh interval, and the panel
          // redraws at the chosen size as soon as it is picked.
          Item {
            width: parent.width
            height: Math.max(textSizeCaption.implicitHeight, textSizeControls.implicitHeight)

            Text {
              id: textSizeCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              // Yields to the stepper rather than sliding under it.
              width: parent.width - textSizeControls.width - Style.space(8)
              text: "Text size"
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.body)
            }

            Row {
              id: textSizeControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-minus (U+F068)
                iconText: "\uf068"
                tooltipText: "Smaller"
                enabled: root.textSizeIndex > 0
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepTextSize(-1)
              }

              Text {
                id: textSizeValue
                anchors.verticalCenter: parent.verticalCenter
                width: settingsColumn.stepperValueWidth
                horizontalAlignment: Text.AlignHCenter
                text: root.textSizeLabel
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.body)
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                // nf-fa-plus (U+F067)
                iconText: "\uf067"
                tooltipText: "Larger"
                enabled: root.textSizeIndex < root.textSizes.length - 1
                foreground: root.foreground
                hoverColor: root.foreground
                fontSize: root.fs(Style.font.bodySmall)
                onClicked: root.stepTextSize(1)
              }
            }
          }

          // The one on/off setting in the panel, so it reads as a switch
          // rather than as another minus/plus pair.
          Item {
            width: parent.width
            height: Math.max(indicatorCaption.implicitHeight, settingsColumn.controlHeight)

            Text {
              id: indicatorCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - indicatorSwitch.width - Style.space(8)
              text: "Dot on the bar for new entries"
              elide: Text.ElideRight
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.body)
            }

            ToggleSwitch {
              id: indicatorSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.newEntryIndicator
              // Same height as the stepper buttons; no cursor ring padding so
              // the row does not grow taller than its neighbours.
              cursorRing: false
              trackHeight: Math.round(settingsColumn.controlHeight)
              foreground: root.foreground
              onToggled: root.setNewEntryIndicator(!root.newEntryIndicator)
            }
          }

          Item {
            width: parent.width
            height: doneButton.implicitHeight

            Button {
              id: doneButton
              anchors.right: parent.right
              text: "Done"
              foreground: root.foreground
              bordered: true
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.settingsOpen = false
            }
          }
        }
      }

      // ------------------------------------------------ shortcuts cheat sheet
      // Sits over the content instead of in the layout, so opening it never
      // resizes the panel or scrolls the list out from under you.
      Rectangle {
        id: shortcutsSheet
        anchors.fill: parent
        visible: root.shortcutsOpen
        implicitHeight: shortcutsColumn.implicitHeight
        color: Color.popups.background
        radius: Style.space(4)

        // Swallows clicks and pointer moves so the list underneath can't be
        // hovered or opened through the sheet.
        HoverHandler {}
        TapHandler { onTapped: root.shortcutsOpen = false }

        Column {
          id: shortcutsColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.space(6)

          Item {
            width: parent.width
            height: Math.max(shortcutsHeading.implicitHeight, shortcutsClose.implicitHeight)

            Text {
              id: shortcutsHeading
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Keyboard shortcuts"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fs(Style.font.subtitle)
              font.bold: true
            }

            PanelActionButton {
              id: shortcutsClose
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-fa-times (U+F00D)
              iconText: ""
              tooltipText: "Close"
              foreground: root.dim
              hoverColor: root.foreground
              fontSize: root.fs(Style.font.bodySmall)
              onClicked: root.shortcutsOpen = false
            }
          }

          Repeater {
            model: root.shortcuts

            Item {
              required property var modelData

              width: parent.width
              height: Math.max(keyLabel.implicitHeight, whatLabel.implicitHeight)

              Text {
                id: keyLabel
                anchors.left: parent.left
                width: Style.space(Math.round(76 * root.textScale))
                text: modelData.keys
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
                font.bold: true
              }

              Text {
                id: whatLabel
                anchors.left: keyLabel.right
                anchors.right: parent.right
                text: modelData.what
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.bodySmall)
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }
}
