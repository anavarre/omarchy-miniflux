// Fake Quickshell.Io StdioCollector: the fake Process writes text directly.
import QtQuick
QtObject {
  property bool waitForEnd: false
  property string text: ""
  signal streamFinished()
}
