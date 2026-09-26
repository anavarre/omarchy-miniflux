// Generated stub of shell/Commons/Style.qml, basecamp/omarchy@e1614f2bdb94f7df11eda072644b31e1e118f1ba.
// Member declarations only, for qmllint; nothing here runs.
pragma Singleton
import QtQuick
QtObject {
  property int cornerRadius: 0
  property int gapsOut: 0
  property var styleOverrides: null
  function styleRawNum(key) {}
  function styleNum(key, fallback) {}
  function styleAlpha(key, fallback) {}
  function styleString(key, fallback) {}
  readonly property string normalColorToken: ""
  readonly property string hoverColorToken: ""
  readonly property string selectedColorToken: ""
  readonly property string pressedColorToken: ""
  readonly property string focusColorToken: ""
  readonly property string selectionColorToken: ""
  readonly property int normalBorderWidth: 0
  readonly property int hoverBorderWidth: 0
  readonly property int selectedBorderWidth: 0
  readonly property int focusBorderWidth: 0
  readonly property real normalFillAlpha: 0
  readonly property real hoverFillAlpha: 0
  readonly property real selectedFillAlpha: 0
  readonly property real pressedFillAlpha: 0
  readonly property real focusFillAlpha: 0
  readonly property real selectionFillAlpha: 0
  readonly property real normalBorderAlpha: 0
  readonly property real hoverBorderAlpha: 0
  readonly property real selectedBorderAlpha: 0
  readonly property real focusBorderAlpha: 0
  function colorFromHex(value, fallback) {}
  function resolveStateColor(token, foreground, accent, urgent, fallback) {}
  function normalStateColor(foreground, accent, urgent) {}
  function hoverStateColor(foreground, accent, urgent) {}
  function selectedStateColor(foreground, accent, urgent) {}
  function pressedStateColor(foreground, accent, urgent) {}
  function focusStateColor(foreground, accent, urgent) {}
  function selectionStateColor(foreground, accent, urgent) {}
  function normalFillFor(foreground, accent, urgent) {}
  function hoverFillFor(foreground, accent, urgent) {}
  function selectedFillFor(foreground, accent, urgent) {}
  function pressedFillFor(foreground, accent, urgent) {}
  function focusFillFor(foreground, accent, urgent) {}
  function selectionFillFor(foreground, accent, urgent) {}
  function normalBorderFor(foreground, accent, urgent) {}
  function hoverBorderFor(foreground, accent, urgent) {}
  function selectedBorderFor(foreground, accent, urgent) {}
  function focusBorderFor(foreground, accent, urgent) {}
  function controlFill(focused, hot, foreground, accent) {}
  function controlBorder(focused, hot, foreground, accent) {}
  function controlBorderWidth(focused, hot) {}
  readonly property color normalFill: "transparent"
  readonly property color hoverFill: "transparent"
  readonly property color selectedFill: "transparent"
  readonly property color pressedFill: "transparent"
  readonly property color focusFillColor: "transparent"
  readonly property color normalBorderColor: "transparent"
  readonly property color hoverBorderColor: "transparent"
  readonly property color selectedBorderColor: "transparent"
  readonly property color focusBorderColor: "transparent"
  readonly property color selectedAccentFill: "transparent"
  readonly property color selectionFill: "transparent"
  property real spacingScale: 0
  property bool spacingScaleWithFont: false
  property var spacingOverrides: null
  readonly property real effectiveSpacingScale: 0
  function spaceReal(px) {}
  function space(px) {}
  function spacingToken(key, fallback) {}
  readonly property var spacing: QtObject {
    readonly property real scale: 0
    readonly property int hairline: 0
    readonly property int xxs: 0
    readonly property int xs: 0
    readonly property int sm: 0
    readonly property int md: 0
    readonly property int lg: 0
    readonly property int xl: 0
    readonly property int xxl: 0
    readonly property int xxxl: 0
    readonly property int huge: 0
    readonly property int controlGap: 0
    readonly property int controlPaddingX: 0
    readonly property int controlPaddingY: 0
    readonly property int inputPaddingY: 0
    readonly property int controlHeight: 0
    readonly property int popupRowHeight: 0
    readonly property int dropdownWidth: 0
    readonly property int searchableDropdownWidth: 0
    readonly property int numberFieldWidth: 0
    readonly property int searchablePopupMinHeight: 0
    readonly property int rowGap: 0
    readonly property int rowPaddingX: 0
    readonly property int labelGap: 0
    readonly property int panelGap: 0
    readonly property int panelPadding: 0
    readonly property int popupPadding: 0
  }
  property string fontFamily: ""
  property string resolvedFontFamily: ""
  property int fontBaseSize: 0
  property var fontOverrides: null
  property var barOverrides: null
  property bool barScaleWithFont: false
  readonly property real fontScale: 0
  function fontPx(mult) {}
  function fontToken(key, fallback) {}
  function barToken(key, fallback) {}
  function boolToken(value, fallback) {}
  readonly property string menuFontFamily: ""
  readonly property var font: QtObject {
    readonly property string family: ""
    readonly property string resolvedFamily: ""
    readonly property string menuFamily: ""
    readonly property int baseSize: 0
    readonly property int caption: 0
    readonly property int bodySmall: 0
    readonly property int body: 0
    readonly property int subtitle: 0
    readonly property int title: 0
    readonly property int heading: 0
    readonly property int display: 0
    readonly property int displayLarge: 0
    readonly property int iconSmall: 0
    readonly property int icon: 0
    readonly property int iconLarge: 0
  }
  readonly property var bar: QtObject {
    readonly property int sizeHorizontal: 0
    readonly property int sizeVertical: 0
    readonly property int iconSlot: 0
    readonly property int iconCanvas: 0
    readonly property int iconFont: 0
    readonly property int statusSlot: 0
  }
  function refresh() {}
  function scheduleRefresh() {}
  function applyRoundingJson(raw) {}
  function applyGapsOutJson(raw) {}
  function applyShellValues(values) {}
  property var hyprctlProc: null
  property var gapsOutProc: null
  function resolveFontFamily() {}
  property var fcMatchProc: null
  property var fontconfigFile: null
  property var refreshTimer: null
  property var windowNoGapsToggle: null
}
