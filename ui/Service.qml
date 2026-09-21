import QtQuick
import Quickshell
import Quickshell.Io

// Mirrors the state of the Teams window, which runs as its own process: the
// host writes a status file, this watches it, and every command goes back
// through the host's CLI. Nothing here talks to Microsoft.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Injected by the shell.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string statusPath: runtimeDir + "/omateams/status.json"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/omateams"
  readonly property string settingsPath: configDir + "/settings.json"
  readonly property string hostBinary: (Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")) + "/omateams/bin/omateams"

  property var settings: ({})
  property bool settingsReceived: false
  property bool installed: false
  property bool installedChecked: false
  property bool running: false
  property bool windowVisible: false
  property int unread: 0
  property bool activity: false
  property string title: ""
  property int pid: 0
  property bool autostartAttempted: false

  readonly property string tooltip: !installedChecked ? "Microsoft Teams"
    : !installed ? "Microsoft Teams — host not built yet: run install.sh in the plugin folder"
    : !running ? "Microsoft Teams — not running (click to start)"
    : unread > 0 ? "Microsoft Teams — " + unread + " unread"
    : activity ? "Microsoft Teams — new activity"
    : "Microsoft Teams"

  // ------------------------------------------------------------ settings
  function applySettings(values) {
    settings = values || ({})
    settingsReceived = true
    var payload = {
      url: settings.url || "https://teams.cloud.microsoft/",
      notifications: settings.notifications === "Off" ? "Off" : "On",
      followTheme: settings.followTheme !== false,
      useShellFont: settings.useShellFont !== false,
      zoom: Number(settings.zoom) || 100,
      closeAction: settings.closeAction === "Quit" ? "Quit" : "Hide window",
      runInBackground: settings.runInBackground !== false,
      updated: Date.now()
    }
    writeSettings(JSON.stringify(payload, null, 2) + "\n")
    maybeAutostart()
  }

  // The file lives in a directory that may not exist yet, so the write goes
  // through a shell that creates it first. The payload travels as an argument.
  function writeSettings(text) {
    if (settingsWriter.running) { pendingSettings = text; return }
    settingsWriter.command = ["sh", "-c", 'mkdir -p "$1" && printf "%s" "$2" > "$3"', "omateams", configDir, text, settingsPath]
    settingsWriter.running = true
  }
  property string pendingSettings: ""

  function maybeAutostart() {
    if (autostartAttempted || !settingsReceived || !installed || running) return
    if (settings.runInBackground === false) return
    autostartAttempted = true
    Quickshell.execDetached([hostBinary, "--hidden"])
  }

  // ------------------------------------------------------------ commands
  function toggle() { command("toggle") }
  function show() { command("show") }
  function hide() { command("hide") }
  function quit() { command("quit") }
  function refresh() { checkInstalled(); statusFile.reload() }

  function command(name) {
    if (!installed) { checkInstalled(); return }
    Quickshell.execDetached([hostBinary, name])
  }

  // ------------------------------------------------------------ status
  function applyStatus(text) {
    var s = null
    try { s = JSON.parse(text) } catch (e) { s = null }
    if (!s || typeof s !== "object") { markStopped(); return }
    unread = Math.max(0, parseInt(s.unread, 10) || 0)
    activity = s.activity === true
    windowVisible = s.visible === true
    title = String(s.title || "")
    pid = parseInt(s.pid, 10) || 0
    if (s.running !== true || pid <= 0) { markStopped(); return }
    running = true
    // A killed host leaves its last file behind; the pid says whether it lives.
    if (!pidCheck.running) {
      pidCheck.command = ["kill", "-0", String(pid)]
      pidCheck.running = true
    }
  }

  function markStopped() {
    running = false
    windowVisible = false
    unread = 0
    activity = false
  }

  function checkInstalled() {
    if (installCheck.running) return
    installCheck.command = ["test", "-x", hostBinary]
    installCheck.running = true
  }

  Component.onCompleted: checkInstalled()

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onFileChanged: reload()
    onLoadFailed: root.markStopped()
  }

  Process {
    id: installCheck
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      root.installedChecked = true
      root.maybeAutostart()
    }
  }

  Process {
    id: pidCheck
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) root.markStopped()
    }
  }

  Process {
    id: settingsWriter
    running: false
    command: []
    onExited: function() {
      if (root.pendingSettings.length > 0) {
        var next = root.pendingSettings
        root.pendingSettings = ""
        root.writeSettings(next)
      }
    }
  }

  // The install check is cheap; repeating it lets the widget notice a host
  // built after the shell started without a restart.
  Timer {
    interval: 60000
    repeat: true
    running: !root.installed
    onTriggered: root.checkInstalled()
  }
}
