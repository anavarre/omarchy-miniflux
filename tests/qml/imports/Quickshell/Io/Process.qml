// Hand-written stub of Quickshell.Io's Process: the members the plugin uses,
// for qmllint. It never starts anything.
import QtQuick
QtObject {
  property var command: []
  property var environment: ({})
  property bool clearEnvironment: false
  property string workingDirectory: ""
  property bool running: false
  property bool stdinEnabled: false
  property var stdout: null
  property var stderr: null
  signal started()
  signal exited(int exitCode, int exitStatus)
  function write(data) {}
  function signal(sig) {}
}
