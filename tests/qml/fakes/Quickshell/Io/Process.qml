// Fake Quickshell.Io Process for tests/qml/service: nothing is ever run.
// Setting running starts it (emitting started); the test ends it with
// finish(), which fills the collectors and emits exited the way a real
// process would.
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
  // What the service wrote to stdin, and how many times it was started.
  property string written: ""
  property int starts: 0
  signal started()
  signal exited(int exitCode, int exitStatus)
  onRunningChanged: if (running) { starts++; started() }
  function write(data) { written += data }
  function signal(sig) {}
  function finish(exitCode, out, err) {
    if (stdout) stdout.text = out || ""
    if (stderr) stderr.text = err || ""
    running = false
    exited(exitCode, 0)
  }
}
