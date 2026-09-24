import QtQuick
import Quickshell
import qs.Ui

BarWidget {
  id: root
  moduleName: "anavarre.miniflux"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  // The panel does the bookkeeping for what counts as new, since it owns the
  // entry list; the widget only paints the dot.
  readonly property bool hasNewEntries: panelLoader.item ? panelLoader.item.hasNewEntries === true : false
  readonly property bool newEntryIndicator: root.setting("newEntryIndicator", true) === true

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // The shell injects settings into widgets, not panels, so they are handed
  // down here — and again whenever the user changes one.
  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.entryLimit = root.setting("entryLimit", 10)
    panelLoader.item.unreadOnly = root.setting("unreadOnly", true) === true
    panelLoader.item.refreshMinutes = root.setting("refreshMinutes", 30)
    panelLoader.item.textSize = root.setting("textSize", "medium")
    panelLoader.item.newEntryIndicator = root.newEntryIndicator
  }

  // The panel's Settings section writes back through here: the widget owns the
  // shell.json entry, so the whole entry is rewritten with the one key changed.
  function saveSetting(name, value) {
    if (!root.bar || !root.bar.shell
        || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[name] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveEntryLimit(limit) { root.saveSetting("entryLimit", limit) }
  function saveRefreshMinutes(minutes) { root.saveSetting("refreshMinutes", minutes) }
  function saveTextSize(size) { root.saveSetting("textSize", size) }
  function saveNewEntryIndicator(on) { root.saveSetting("newEntryIndicator", on === true) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-rss (U+F09E)
    text: ""
    tooltipText: root.newEntryIndicator && root.hasNewEntries
      ? "Miniflux — new entries since you last looked"
      : "Miniflux — latest unread entries"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }

    // A dot on the glyph's upper right: enough to notice in passing, small
    // enough not to shift anything else on the bar.
    Rectangle {
      id: newDot
      visible: root.newEntryIndicator && root.hasNewEntries
      width: Math.max(4, Math.round(button.fontSize * 0.34))
      height: width
      radius: width / 2
      color: button.activeColor
      z: 1
      anchors.horizontalCenter: button.horizontalCenter
      anchors.verticalCenter: button.verticalCenter
      anchors.horizontalCenterOffset: Math.round(button.labelWidth / 2)
      anchors.verticalCenterOffset: -Math.round(button.fontSize * 0.42)
    }
  }
}
