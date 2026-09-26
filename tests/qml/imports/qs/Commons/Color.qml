// Generated stub of shell/Commons/Color.qml, basecamp/omarchy@e1614f2bdb94f7df11eda072644b31e1e118f1ba.
// Member declarations only, for qmllint; nothing here runs.
pragma Singleton
import QtQuick
QtObject {
  readonly property string home: ""
  readonly property string stateHome: ""
  readonly property string currentThemePath: ""
  property color foreground: "transparent"
  property color background: "transparent"
  property color accent: "transparent"
  property color urgent: "transparent"
  property color muted: "transparent"
  property var shellValues: null
  function pick(key, fallback) {}
  function pickAlpha(key, fallback) {}
  function firstColorToken(value) {}
  function flatColor(value, fallback) {}
  function composed(colorKey, alphaKey, colorFallback, alphaFallback) {}
  readonly property var bar: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color active: "transparent"
  }
  readonly property var popups: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color border: "transparent"
  }
  readonly property var tooltip: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color border: "transparent"
  }
  readonly property var notifications: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color border: "transparent"
    property color countdown: "transparent"
  }
  readonly property var menu: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color border: "transparent"
    property color scrim: "transparent"
    property color selectedBackground: "transparent"
    property color selectedText: "transparent"
    property color selectedBorder: "transparent"
  }
  readonly property var polkit: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color textError: "transparent"
    property color border: "transparent"
    property color borderError: "transparent"
    property color accent: "transparent"
    property color scrim: "transparent"
  }
  readonly property var lock: QtObject {
    property color background: "transparent"
    property color text: "transparent"
    property color placeholder: "transparent"
    property color textError: "transparent"
    property color border: "transparent"
    property color borderActive: "transparent"
    property color borderError: "transparent"
    property color selection: "transparent"
  }
  readonly property var imagePicker: QtObject {
    property color scrim: "transparent"
    property color text: "transparent"
    property color selectedBorder: "transparent"
    property color unselectedBorder: "transparent"
  }
  function loadColors(raw) {}
}
