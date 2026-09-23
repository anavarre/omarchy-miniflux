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
  property int entryLimit: 20
  property bool unreadOnly: true

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

  property bool loading: false
  property string errorText: ""
  property var entries: []
  property int total: 0
  property int selected: -1

  // Entries being marked read are dropped from the list as soon as the
  // request goes out — the round trip is the slow part, and a row that lingers
  // invites a second click on something already gone. A failure puts the whole
  // list back by refetching.
  property var pending: []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property real cardWidth: panel.fittedContentWidth(Style.space(460))
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

  function markAllRead() {
    var ids = []
    for (var i = 0; i < root.entries.length; i++) ids.push(root.entries[i].id)
    root.markRead(ids)
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
    root.selected = -1
    if (root.authenticated) root.refresh()
    else if (!root.configuring) root.checkAuth()
    if (root.showSignIn) Qt.callLater(function() { serverField.forceActiveFocus() })
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
      if (ok) return
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
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // The sign-in form owns the keyboard while it is up, so typing a
      // password doesn't drive the list underneath it.
      blocked: root.showSignIn
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveSelection(dy) }
      onActivateRequested: root.openEntry(root.selected)
      onCloseRequested: root.close()
      onDeleteRequested: root.markSelectedRead()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "a") root.markAllRead()
        else if (text === "c") root.openSignIn()
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
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            width: parent.width
            visible: root.authHint !== "" && root.authError === ""
            text: root.authHint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.authError !== ""
            text: root.authError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          TextField {
            id: serverField
            width: parent.width
            foreground: root.foreground
            placeholderText: "miniflux.example.org"
            onAccepted: userField.forceActiveFocus()
            Keys.onEscapePressed: root.cancelSignIn()
          }

          TextField {
            id: userField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Username"
            onAccepted: passField.forceActiveFocus()
            Keys.onEscapePressed: root.cancelSignIn()
          }

          TextField {
            id: passField
            width: parent.width
            foreground: root.foreground
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
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: root.saving ? "Signing in…" : "Sign in"
              enabled: !root.saving
              foreground: root.foreground
              bordered: true
              onClicked: root.saveSignIn()
            }

            Button {
              visible: root.authenticated
              text: "Cancel"
              foreground: root.foreground
              onClicked: root.cancelSignIn()
            }

            Button {
              visible: root.hasSecret
              text: "Forget credentials"
              foreground: root.foreground
              onClicked: root.forgetSignIn()
            }
          }
        }

        // ---------------------------------------------------------- the list
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.showSignIn

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
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              id: headingMeta
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: {
                if (root.loading) return "Fetching…"
                var parts = []
                if (root.total > root.entries.length) parts.push(root.entries.length + " of " + root.total)
                if (root.account !== "") parts.push(root.account)
                return parts.join(" · ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            width: parent.width
            visible: root.errorText !== ""
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: !root.loading && root.errorText === "" && root.entries.length === 0
            text: root.unreadOnly ? "Nothing unread." : "No entries."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
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
                        font.pixelSize: Style.font.body
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
                        font.pixelSize: Style.font.caption
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
                      fontSize: Style.font.bodySmall
                      onClicked: root.markRead([modelData.id])
                    }
                  }
                }
              }
            }
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "Refresh"
              enabled: !root.loading
              foreground: root.foreground
              fontSize: Style.font.bodySmall
              onClicked: root.refresh()
            }

            Button {
              text: "Mark all read"
              enabled: root.entries.length > 0
              foreground: root.foreground
              fontSize: Style.font.bodySmall
              onClicked: root.markAllRead()
            }

            Button {
              text: "Account"
              foreground: root.dim
              fontSize: Style.font.bodySmall
              onClicked: root.openSignIn()
            }
          }

          Text {
            width: parent.width
            text: "j/k move · Enter opens · x marks read · a marks all · r refreshes"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
