import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "anavarre.miniflux"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // The plugin's Service.qml singleton, handed down by the bar widget. It owns
  // sign-in, the entry list and every request; this panel is one monitor's
  // view of it. Until the service appears, or under a bar that hands out no
  // service, the panel reads an inert stand-in so every binding still has
  // something to read.
  property var service: null
  readonly property var miniflux: root.service || inertService

  // Settings the service acts on. The Settings section writes them back
  // through the service and the widget, which owns the shell.json entry.
  readonly property int entryLimit: root.miniflux.entryLimit
  // 1 up to the API's own ceiling, so the list can be as short or as long as
  // the user wants it.
  readonly property int entryLimitMin: Model.entryLimitMin
  readonly property int entryLimitMax: Model.entryLimitMax
  readonly property bool unreadOnly: root.miniflux.unreadOnly
  // Minutes between automatic refreshes; always one of the allowed steps.
  readonly property int refreshMinutes: root.miniflux.refreshMinutes
  // 30 minutes up to a day, so the interval can never hammer the instance.
  readonly property var refreshChoices: Model.refreshChoices
  readonly property int refreshMin: refreshChoices[0]
  readonly property int refreshMax: refreshChoices[refreshChoices.length - 1]

  // Whether a refresh that brings in unseen entries lights up the bar icon.
  // Pushed in by the bar widget, which paints the dot.
  property bool newEntryIndicator: true

  // Text size is offered as named sizes rather than pixel values — the user
  // picks how big the panel reads, and every font size in it is scaled by the
  // matching factor.
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

  // Shared state, read straight off the service.
  readonly property string authState: root.miniflux.authState
  readonly property string authHint: root.miniflux.authHint
  readonly property string authError: root.miniflux.authError
  readonly property string account: root.miniflux.account
  readonly property bool authenticated: root.miniflux.authenticated === true
  readonly property bool saving: root.miniflux.saving === true
  readonly property bool hasSecret: root.miniflux.hasSecret === true
  readonly property bool loading: root.miniflux.loading === true
  readonly property string errorText: root.miniflux.errorText
  readonly property string saveNotice: root.miniflux.saveNotice
  readonly property var entries: root.miniflux.entries
  readonly property int total: root.miniflux.total
  readonly property int listedUnread: root.miniflux.listedUnread

  // The sign-in form. It opens by itself when there is nothing stored or what
  // is stored no longer works, and on demand from "Account".
  property bool configuring: false
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
    { keys: "Shift+a", what: "Mark the listed entries read" },
    { keys: "r", what: "Refresh now" },
    { keys: "s", what: "Save the selected entry" },
    { keys: ",", what: "Settings" },
    { keys: "c", what: "Account / sign in" },
    { keys: "Tab", what: "Switch to the next panel" },
    { keys: "?", what: "Show or hide this list" },
    { keys: "Esc", what: "Close" }
  ]

  // Local to this monitor: which row the keyboard is on.
  property int selected: -1

  // The service counts open panels, so a background refresh only lights the
  // bar dot while nobody is looking. This remembers which service object was
  // told, so the matching close reaches the same one.
  property var countedIn: null

  function trackOpen() {
    if (root.countedIn) return
    root.countedIn = root.miniflux
    root.countedIn.panelOpened()
  }

  function trackClose() {
    if (!root.countedIn) return
    var counted = root.countedIn
    root.countedIn = null
    // The service may already be gone if the plugin was disabled while open.
    try { counted.panelClosed() } catch (e) {}
  }

  function setNewEntryIndicator(on) {
    if (on === root.newEntryIndicator) return
    root.newEntryIndicator = on
    if (!on) root.miniflux.clearNewEntries()
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

  // Fills whichever sign-in fields are still empty from what is on file.
  function prefillSignIn() {
    if (serverField.text === "") serverField.text = root.miniflux.storedServer
    if (userField.text === "") userField.text = root.miniflux.storedUsername
  }

  function openSignIn() {
    root.settingsOpen = false
    root.configuring = true
    root.miniflux.clearAuthMessages()
    root.prefillSignIn()
    root.miniflux.loadConfig()
    Qt.callLater(function() { serverField.forceActiveFocus() })
  }

  function saveSignIn() {
    if (root.saving) return
    root.miniflux.signIn(serverField.text, userField.text, passField.text)
  }

  function cancelSignIn() {
    if (!root.authenticated) { root.close(); return }
    root.configuring = false
    passField.text = ""
    root.miniflux.clearAuthMessages()
  }

  function forgetSignIn() {
    root.miniflux.forget()
  }

  // Snaps whatever comes in to the nearest allowed choice, so a stored value
  // from an older version still lands on something valid.
  function setRefreshMinutes(minutes) {
    var n = Model.snapRefreshMinutes(minutes)
    if (n === root.refreshMinutes) return
    root.miniflux.refreshMinutes = n
    if (root.hostWidget && typeof root.hostWidget.saveRefreshMinutes === "function")
      root.hostWidget.saveRefreshMinutes(n)
  }

  // Written back through the widget like the other panel-side settings. The
  // service refetches on its own when the limit changes.
  function setEntryLimit(value) {
    if (!isFinite(Math.round(Number(value)))) return
    var n = Model.clampEntryLimit(value)
    if (n === root.entryLimit) return
    root.miniflux.entryLimit = n
    if (root.hostWidget && typeof root.hostWidget.saveEntryLimit === "function")
      root.hostWidget.saveEntryLimit(n)
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

  function refresh() { root.miniflux.refresh() }

  function openEntry(index) {
    if (index < 0 || index >= root.entries.length) return
    var entry = root.entries[index]
    // The url is feed content, so it is whatever the item's author wrote.
    // openUrlExternally dispatches on scheme to any registered handler, so
    // only the two schemes an article can legitimately live at get through.
    if (!/^https?:\/\//i.test(entry.url)) return
    Qt.openUrlExternally(entry.url)
    root.close()
  }

  function markRead(ids) { root.miniflux.markRead(ids) }

  function markSelectedRead() {
    if (root.selected < 0 || root.selected >= root.entries.length) return
    root.markRead([root.entries[root.selected].id])
  }

  function markAllRead() { root.miniflux.markAllRead() }

  function saveSelected() {
    if (root.selected < 0 || root.selected >= root.entries.length) return
    root.miniflux.saveEntry(root.entries[root.selected].id)
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
  // The service already holds the last list, so that shows while it fetches.
  //
  // Every close path (Escape, outside click, opening an entry, the host
  // hiding the panel) lands here. A typed password never outlives the panel
  // it was typed into, and the cheat sheet does not greet the next open. A
  // sign-in already sent has read the field, so clearing it cannot cut one
  // short.
  onOpenedChanged: {
    if (!opened) {
      passField.text = ""
      root.shortcutsOpen = false
      root.trackClose()
      return
    }
    root.trackOpen()
    root.selected = -1
    root.settingsOpen = false
    if (root.authenticated) root.miniflux.refresh()
    else if (!root.configuring) root.miniflux.checkAuth()
    if (root.showSignIn) Qt.callLater(function() { serverField.forceActiveFocus() })
  }

  onShowSignInChanged: {
    if (!root.opened || !root.showSignIn) return
    root.prefillSignIn()
    Qt.callLater(function() { serverField.forceActiveFocus() })
  }

  Component.onDestruction: root.trackClose()

  Connections {
    target: root.miniflux
    ignoreUnknownSignals: true
    function onSignedIn() {
      passField.text = ""
      root.configuring = false
    }
    function onForgotten() {
      passField.text = ""
      root.configuring = true
      if (root.opened) Qt.callLater(function() { serverField.forceActiveFocus() })
    }
    function onAuthenticatedChanged() {
      if (root.miniflux.authenticated) root.configuring = false
    }
    function onStoredServerChanged() { root.prefillSignIn() }
    function onStoredUsernameChanged() { root.prefillSignIn() }
    // A refresh or a mark on another monitor can shorten the list under this
    // one's selection.
    function onEntriesChanged() {
      root.selected = Math.min(root.selected, root.miniflux.entries.length - 1)
    }
  }

  // Stands in for the service until it exists. Everything is idle and every
  // action is a no-op; the list section says why nothing is there.
  QtObject {
    id: inertService
    property int entryLimit: 10
    property bool unreadOnly: true
    property int refreshMinutes: 30
    property string authState: "unavailable"
    property string authHint: ""
    property string authError: ""
    property string account: ""
    readonly property bool authenticated: false
    property bool saving: false
    property bool hasSecret: false
    property string storedServer: ""
    property string storedUsername: ""
    property bool loading: false
    property string errorText: "The Miniflux service is not running. Re-enable the plugin; under a third-party bar, switch back to Omarchy's own bar."
    property string saveNotice: ""
    property var entries: []
    property int total: 0
    readonly property int listedUnread: 0
    signal signedIn()
    signal forgotten()
    function panelOpened() {}
    function panelClosed() {}
    function clearNewEntries() {}
    function clearAuthMessages() {}
    function loadConfig() {}
    function signIn(server, username, password) {}
    function forget() {}
    function checkAuth() {}
    function refresh() {}
    function markRead(ids) {}
    function markAllRead() {}
    function saveEntry(id) {}
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
        else if (text === "A") root.markAllRead()
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
            textFormat: Text.PlainText
            text: root.authHint
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.authError !== ""
            textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            text: root.saveNotice
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: root.fs(Style.font.bodySmall)
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.errorText !== ""
            textFormat: Text.PlainText
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
                        // Feed text, so never AutoText: rich text would let a
                        // title pull a remote <img> when the panel opens.
                        textFormat: Text.PlainText
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
                        textFormat: Text.PlainText
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
