// Generated stub of shell/Ui/WidgetButton.qml, basecamp/omarchy@e1614f2bdb94f7df11eda072644b31e1e118f1ba.
// Member declarations only, for qmllint; nothing here runs.
import QtQuick
Item {
  property var bar: null
  property string text: ""
  property string fontFamily: ""
  property real fontSize: 0
  property color foreground: "transparent"
  property color activeColor: "transparent"
  property bool active: false
  property real horizontalMargin: 0
  property real verticalPadding: 0
  property real fixedWidth: 0
  property real fixedHeight: 0
  property real textRotation: 0
  property bool keepSpace: false
  property bool dimmed: false
  property bool concealed: false
  property bool interactive: false
  property bool pressable: false
  property bool useActiveColor: false
  property bool maintainIndicatorReveal: false
  property bool labelVisible: false
  property bool hasVisualContent: false
  property var revealHost: null
  property string tooltipText: ""
  property var registeredBar: null
  signal pressed(int button)
  signal wheelMoved(int delta)
  function triggerPress(button) {}
  function hideOwnTooltip() {}
  function syncClickRegistration() {}
  readonly property bool vertical: false
  readonly property int barSize: 0
  readonly property real scaledHorizontalMargin: 0
  readonly property real scaledVerticalPadding: 0
  readonly property bool tooltipHovered: false
  readonly property real labelWidth: 0
}
