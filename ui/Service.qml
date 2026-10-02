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
  // install.sh sits next to ui/ in the plugin folder `omarchy plugin add` cloned.
  readonly property string installScript: decodeURIComponent(String(Qt.resolvedUrl("../install.sh")).replace(/^file:\/\//, ""))

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
  // "", "building", "needs-deps" or "failed": the state of the automatic build.
  property string buildState: ""
  property string missingPackages: ""
  // The exit code and the output arrive separately; the result is handled
  // once both are in, whichever comes first.
  property int builderExit: -1
  property var builderText: null

  readonly property string tooltip: buildState === "building" ? "Microsoft Teams — setting up the Teams window…"
    : buildState === "needs-deps" ? "Microsoft Teams — needs " + missingPackages + ": click to open the package installer"
    : buildState === "failed" ? "Microsoft Teams — setup failed: click to retry in a terminal"
    : !installedChecked ? "Microsoft Teams"
    : !installed ? "Microsoft Teams — Teams window not set up yet"
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
    if (buildState === "needs-deps") { openPackageInstaller(); return }
    if (buildState === "failed") { installInTerminal(); return }
    if (!installed) { ensureHost(); return }
    Quickshell.execDetached([hostBinary, name])
  }

  // ------------------------------------------------------------ host build
  // `omarchy plugin add` only clones the repository, and the Teams window is a
  // small Qt program that has to be compiled. The service builds it on load;
  // install.sh --if-needed returns at once when the binary already matches the
  // plugin version, its sources and the installed Qt, so after `omarchy plugin
  // update` or a Qt upgrade the next shell start rebuilds it without asking.
  function ensureHost() {
    if (builder.running) return
    // A retry while packages are missing stays quiet until something changes.
    if (buildState !== "needs-deps") buildState = "building"
    builderExit = -1
    builderText = null
    builder.command = ["bash", installScript, "--if-needed"]
    builder.running = true
  }

  // The plugin installs no system packages itself. A missing build dependency
  // is named in a notification, and a click opens Omarchy's own package
  // installer; the retry timer below builds as soon as the packages are there.
  function openPackageInstaller() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-pkg-install"])
  }

  // A failed build is retried in a terminal, where its output can be read.
  function installInTerminal() {
    buildState = ""
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "bash '" + installScript.replace(/'/g, "'\\''") + "'"])
  }

  function notify(body) {
    Quickshell.execDetached(["notify-send", "-a", "Omateams", "-i", "omateams", "Microsoft Teams", body])
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

  Component.onCompleted: ensureHost()

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
    id: builder
    running: false
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.builderText = text; root.buildFinished() }
    }
    onExited: function(exitCode) { root.builderExit = exitCode; root.buildFinished() }
  }

  function buildFinished() {
    if (builderExit < 0 || builderText === null) return
    var exitCode = builderExit
    builderExit = -1
    if (exitCode === 0) {
      buildState = ""
    } else if (exitCode === 10) {
      buildState = ""
      if (!running)
        notify("The Teams window is ready. Click the Teams icon in the bar to sign in.")
    } else if (exitCode === 3) {
      var missing = String(builderText).trim().split(/\s+/).filter(function(p) { return p.length > 0 }).join(", ") || "build packages"
      var changed = buildState !== "needs-deps" || missingPackages !== missing
      missingPackages = missing
      buildState = "needs-deps"
      if (changed)
        notify("The Teams window needs " + missing + ". Click the Teams icon in the bar to open the package installer; setup continues on its own once they are installed.")
    } else {
      buildState = "failed"
      notify("Setting up the Teams window failed. Click the Teams icon in the bar to retry in a terminal.")
    }
    checkInstalled()
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
  // built in a terminal after the shell started without a restart.
  Timer {
    interval: 60000
    repeat: true
    running: !root.installed || root.buildState === "needs-deps"
    onTriggered: root.buildState === "needs-deps" ? root.ensureHost() : root.checkInstalled()
  }
}
