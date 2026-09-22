import QtQuick
import QtQuick.Window
import QtWebEngine
import "Theme.js" as Theme
import "WebAuth.js" as WebAuth

// The Teams window. The real Teams web client runs in a WebEngineView; this
// file owns everything around it: the persistent profile, the Omarchy theme
// stylesheet and its live reload, desktop notifications, downloads, sign-in
// popups, the status file the bar widget reads, and the socket commands the
// widget and the CLI send.
Window {
  id: win

  // Set by main.cpp from the command line.
  property bool startHidden: false
  property string startUrl: ""

  readonly property string home: Sys.home()
  readonly property string statusPath: Sys.runtimeDir() + "/omateams/status.json"
  readonly property string configDir: Sys.configDir() + "/omateams"
  readonly property string settingsPath: configDir + "/settings.json"
  readonly property string windowStatePath: Sys.stateDir() + "/omateams/window.json"
  readonly property string omarchyState: home + "/.local/state/omarchy/current"
  readonly property string colorsPath: omarchyState + "/theme/colors.toml"
  readonly property string defaultUrl: "https://teams.cloud.microsoft/"

  // Written by the Omarchy bar widget from its plugin settings.
  property var settings: ({})
  readonly property bool themeEnabled: settings.followTheme !== false
  readonly property bool notificationsEnabled: settings.notifications !== "Off" && settings.notifications !== false
  readonly property bool hideOnClose: settings.closeAction !== "Quit"
  readonly property string fontFamily: settings.useShellFont === false ? "" : "monospace"
  readonly property real zoom: Math.max(0.5, Math.min(3, (Number(settings.zoom) || 100) / 100))

  property var themeColors: ({})
  readonly property var themePalette: Theme.palette(themeColors)
  property string themeCss: ""
  property int rounding: -1
  property int roundingRequest: -1
  property bool ready: false

  property int unread: 0
  property bool activity: false
  property var pendingNotifications: ({})
  property bool quitting: false
  property int windowedVisibility: Window.Windowed

  readonly property string focusCommand:
    "hyprctl dispatch 'hl.dsp.focus({ window = \"class:omateams\" })' >/dev/null 2>&1"
    + " || hyprctl dispatch focuswindow class:omateams >/dev/null 2>&1"

  visible: !startHidden
  width: 1280
  height: 860
  minimumWidth: 480
  minimumHeight: 320
  title: view.title.length > 0 ? view.title : "Microsoft Teams"
  color: themeColors.background && /^#[0-9a-fA-F]{6}$/.test(themeColors.background) ? themeColors.background : "#101315"

  // Closing hides by default: the badge and the notifications only work while
  // the page keeps running. Quit comes from the CLI, Ctrl+Q, or the setting.
  onClosing: function(close) {
    if (hideOnClose && !quitting) {
      close.accepted = false
      win.hide()
    }
  }
  onVisibleChanged: statusTimer.restart()
  onActiveChanged: statusTimer.restart()
  onWidthChanged: geometryTimer.restart()
  onHeightChanged: geometryTimer.restart()
  onThemeEnabledChanged: if (ready) rebuildCss()
  onFontFamilyChanged: if (ready) rebuildCss()

  Component.onCompleted: {
    installWebAuthScript()
    loadSettings()
    restoreGeometry()
    loadTheme()
    refreshRounding()
    Sys.watch(colorsPath)
    Sys.watch(omarchyState)
    Sys.watch(settingsPath)
    Sys.watch(configDir)
    ready = true
    view.url = startUrl.length > 0 ? startUrl : (settings.url || defaultUrl)
    writeStatus()
  }

  // ------------------------------------------------------------ settings
  function safeJson(text) {
    try { var v = JSON.parse(text); return v && typeof v === "object" ? v : null } catch (e) { return null }
  }

  function loadSettings() {
    var raw = Sys.readFile(settingsPath)
    if (raw.length === 0) {
      // Create the file so the directory exists and the watch can arm; the
      // bar widget replaces it with the real values on its first run.
      Sys.writeFile(settingsPath, "{}\n")
      Sys.watch(settingsPath)
      Sys.watch(configDir)
    }
    settings = safeJson(raw) || ({})
  }

  // ------------------------------------------------------------ theme
  function loadTheme() {
    themeColors = Theme.parseColors(Sys.readFile(colorsPath))
    rebuildCss()
  }

  function rebuildCss() {
    themeCss = themeEnabled ? Theme.buildCss(themeColors, { fontFamily: fontFamily, rounding: rounding }) : ""
    installThemeScript()
    applyThemeLive()
  }

  // The stylesheet rides in a user script at document creation so a fresh
  // page never flashes Microsoft's colors; the running page is restyled in
  // place through the hook the script leaves on window.
  function installThemeScript() {
    var old = profile.userScripts.find("omateams-theme")
    for (var i = 0; i < old.length; i++) profile.userScripts.remove(old[i])
    if (themeCss.length === 0) return
    var script = WebEngine.script()
    script.name = "omateams-theme"
    script.sourceCode = Theme.pageScript(themeCss)
    script.injectionPoint = WebEngineScript.DocumentCreation
    script.worldId = WebEngineScript.MainWorld
    script.runOnSubframes = true
    profile.userScripts.insert(script)
  }

  // Runs for every page and frame, theme or not: it is the only thing standing
  // between a passkey prompt that cannot be served and a sign-in page that
  // spins for good. See WebAuth.js.
  function installWebAuthScript() {
    var script = WebEngine.script()
    script.name = "omateams-webauth"
    script.sourceCode = WebAuth.pageScript()
    script.injectionPoint = WebEngineScript.DocumentCreation
    script.worldId = WebEngineScript.MainWorld
    script.runOnSubframes = true
    profile.userScripts.insert(script)
  }

  function applyThemeLive() {
    if (!ready) return
    var css = JSON.stringify(themeCss)
    view.runJavaScript(
      "if (window.__omateamsApply) window.__omateamsApply(" + css + ");"
      + " else { var s = document.getElementById('omateams-theme'); if (s) s.remove(); }")
  }

  // Corner radii follow Hyprland's rounding, which a theme may change too.
  function refreshRounding() {
    roundingRequest = Sys.runCapture("hyprctl", ["getoption", "decoration:rounding", "-j"])
  }

  // ------------------------------------------------------------ status
  function statusObject() {
    return {
      running: !quitting,
      pid: Sys.pid(),
      version: appVersion,
      visible: win.visible,
      active: win.active,
      unread: unread,
      activity: activity,
      title: String(view.title || ""),
      url: String(view.url || ""),
      updated: Date.now()
    }
  }

  function writeStatus() {
    Sys.writeFile(statusPath, JSON.stringify(statusObject(), null, 2) + "\n")
  }

  // Teams prefixes the document title with the unread count, "(3) Chat | …",
  // or a dot when there is activity without a count.
  function parseTitle() {
    var t = String(view.title || "")
    var m = t.match(/^\((\d+)\)/)
    unread = m ? parseInt(m[1], 10) : 0
    activity = !m && /^[•●*]/.test(t)
    statusTimer.restart()
  }

  // ------------------------------------------------------------ window
  function showWindow() {
    win.show()
    win.raise()
    win.requestActivate()
    focusTimer.restart()
  }

  function restoreGeometry() {
    var s = safeJson(Sys.readFile(windowStatePath))
    if (!s) return
    if (Number(s.width) >= minimumWidth) win.width = Number(s.width)
    if (Number(s.height) >= minimumHeight) win.height = Number(s.height)
  }

  function handleCommand(connection, line) {
    var cmd = line.split(/\s+/)[0]
    switch (cmd) {
    case "show": showWindow(); Sys.reply(connection, "ok"); break
    case "hide": win.hide(); Sys.reply(connection, "ok"); break
    case "toggle":
      if (win.visible) win.hide(); else showWindow()
      Sys.reply(connection, "ok")
      break
    case "status": Sys.reply(connection, JSON.stringify(statusObject())); break
    case "reload-theme": loadTheme(); refreshRounding(); Sys.reply(connection, "ok"); break
    case "quit": Sys.reply(connection, "ok"); quit(); break
    default: Sys.reply(connection, "unknown command: " + cmd)
    }
  }

  function quit() {
    quitting = true
    writeStatus()
    Qt.quit()
  }

  // ------------------------------------------------------------ origins
  function hostOf(url) {
    var m = String(url || "").match(/^[a-z]+:\/\/([^\/:?#]+)/i)
    return m ? m[1].toLowerCase() : ""
  }

  function hostMatches(host, suffixes) {
    for (var i = 0; i < suffixes.length; i++) {
      var s = suffixes[i]
      if (host === s || host.endsWith("." + s)) return true
    }
    return false
  }

  // Origins allowed to use the microphone, camera, screen, clipboard and
  // notifications: Teams itself and the Microsoft services it embeds.
  function isTeamsOrigin(url) {
    return hostMatches(hostOf(url), [
      "cloud.microsoft", "teams.microsoft.com", "microsoft.com", "office.com", "office.net",
      "sharepoint.com", "skype.com", "live.com", "microsoftonline.com", "microsoftstream.com"
    ])
  }

  // Sign-in hosts whose popups belong in an in-app dialog rather than the
  // system browser, so the session cookie ends up in this profile.
  function isSignInOrigin(url) {
    return hostMatches(hostOf(url), [
      "login.microsoftonline.com", "login.microsoft.com", "login.live.com", "login.windows.net",
      "account.microsoft.com", "account.live.com", "msauth.net", "msftauth.net",
      "microsoftazuread-sso.com", "aadcdn.msauth.net", "aadcdn.msftauth.net"
    ])
  }

  // ------------------------------------------------------------ notifications
  // The security key is the one kind of passkey this window can use: Chromium
  // on Linux has no authenticator of its own, and the phone-and-QR-code route
  // needs a Chromium UI that QtWebEngine does not carry.
  function reportWebAuth(message) {
    if (String(message).indexOf(WebAuth.MARKER) !== 0) return
    Sys.run("notify-send", ["-a", "Microsoft Teams", "-i", "omateams",
      "Passkey sign-in did not work",
      "No security key answered. Passkeys kept on this device or on your phone cannot be used here \u2014 sign in with your password or the Authenticator app."])
  }

  function presentNotification(notification) {
    if (!notificationsEnabled) { notification.close(); return }
    var id = Sys.runCapture("notify-send", [
      "-a", "Microsoft Teams", "-i", "omateams",
      "-h", "string:desktop-entry:omateams",
      "-A", "default=Open",
      String(notification.title || "Microsoft Teams"),
      String(notification.message || "")
    ])
    var pending = pendingNotifications
    pending[id] = notification
    pendingNotifications = pending
    notification.closed.connect(function() {
      var p = win.pendingNotifications
      if (p[id] === notification) delete p[id]
    })
  }

  function startDownload(download) {
    download.downloadDirectory = home + "/Downloads"
    download.accept()
    download.stateChanged.connect(function() {
      if (download.state !== WebEngineDownloadRequest.DownloadCompleted) return
      Sys.run("notify-send", ["-a", "Microsoft Teams", "-i", "omateams", "Download finished", String(download.downloadFileName)])
    })
  }

  // ------------------------------------------------------------ wiring
  Connections {
    target: Sys
    function onFileChanged(path) {
      var p = String(path)
      if (p === win.settingsPath || p === win.configDir) settingsTimer.restart()
      else themeTimer.restart()
    }
    function onProcessFinished(id, exitCode, output) {
      if (id === win.roundingRequest) {
        win.roundingRequest = -1
        var parsed = win.safeJson(output)
        var value = parsed && typeof parsed.int === "number" ? parsed.int : -1
        if (exitCode === 0 && value !== win.rounding) { win.rounding = value; win.rebuildCss() }
        return
      }
      var notification = win.pendingNotifications[id]
      if (!notification) return
      var pending = win.pendingNotifications
      delete pending[id]
      win.pendingNotifications = pending
      if (String(output).trim() === "default") {
        win.showWindow()
        notification.click()
      }
    }
    function onCommand(connection, line) { win.handleCommand(connection, line) }
  }

  Connections {
    target: Qt.application
    function onAboutToQuit() { win.quitting = true; win.writeStatus() }
  }

  Timer { id: statusTimer; interval: 250; onTriggered: win.writeStatus() }
  Timer { id: heartbeat; interval: 60000; repeat: true; running: true; onTriggered: win.writeStatus() }
  Timer { id: focusTimer; interval: 150; onTriggered: Sys.run("sh", ["-c", win.focusCommand]) }
  Timer {
    id: geometryTimer
    interval: 800
    onTriggered: if (win.visibility === Window.Windowed)
      Sys.writeFile(win.windowStatePath, JSON.stringify({ width: win.width, height: win.height }) + "\n")
  }
  Timer {
    id: settingsTimer
    interval: 200
    onTriggered: { win.loadSettings(); Sys.watch(win.settingsPath) }
  }
  // A theme switch rewrites the whole theme directory; wait for it to settle.
  Timer {
    id: themeTimer
    interval: 400
    onTriggered: { win.loadTheme(); win.refreshRounding(); Sys.watch(win.colorsPath); Sys.watch(win.omarchyState) }
  }
  Timer { id: reloadTimer; interval: 1500; onTriggered: view.reload() }

  Shortcut { sequences: ["Ctrl+Q"]; onActivated: win.quit() }
  Shortcut { sequences: ["Ctrl+W"]; onActivated: win.hide() }
  Shortcut { sequences: ["Ctrl+R", "F5"]; onActivated: view.reload() }
  Shortcut { sequences: ["Ctrl+Shift+T"]; onActivated: { win.loadTheme(); win.refreshRounding() } }

  Component { id: authWindow; AuthWindow {} }
  Component { id: webAuthDialog; WebAuthDialog {} }

  // Chromium leaves the whole WebAuthn user experience to the application: the
  // PIN, the account to use, the "touch your key now" and the reason a key was
  // refused all arrive here as a request that waits for an answer. A window
  // that ignores it shows a sign-in that can never finish, so the dialog takes
  // the request over and answers it in every case, closing included.
  function showWebAuthUx(request, parentWindow) {
    var dialog = webAuthDialog.createObject(parentWindow, {
      request: request,
      pal: win.themePalette,
      radius: win.rounding >= 0 ? win.rounding : 8,
      transientParent: parentWindow
    })
    if (!dialog) { request.cancel(); return }
    dialog.show()
    dialog.requestActivate()
  }

  WebEngineProfile {
    id: profile
    storageName: "teams"
    offTheRecord: false
    persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    httpCacheType: WebEngineProfile.DiskHttpCache

    // Teams gates features on the browser it sees. The embedded Chromium is a
    // current one; only the QtWebEngine token stops Teams recognising it.
    Component.onCompleted: httpUserAgent = httpUserAgent.replace(/\s*QtWebEngine\/[\d.]+/, "")

    onPresentNotification: function(notification) { win.presentNotification(notification) }
    onDownloadRequested: function(download) { win.startDownload(download) }
  }

  WebEngineView {
    id: view
    anchors.fill: parent
    profile: profile
    zoomFactor: win.zoom
    backgroundColor: win.color

    settings.javascriptCanOpenWindows: true
    settings.javascriptCanAccessClipboard: true
    settings.javascriptCanPaste: true
    settings.allowWindowActivationFromJavaScript: true
    settings.fullScreenSupportEnabled: true
    settings.playbackRequiresUserGesture: false
    settings.screenCaptureEnabled: true
    settings.pdfViewerEnabled: true
    settings.dnsPrefetchEnabled: true

    onTitleChanged: win.parseTitle()
    onJavaScriptConsoleMessage: function(level, message) { win.reportWebAuth(message) }
    onUrlChanged: statusTimer.restart()

    onPermissionRequested: function(permission) {
      if (win.isTeamsOrigin(permission.origin)) permission.grant()
      else permission.deny()
    }

    onWebAuthUxRequested: function(request) { win.showWebAuthUx(request, win) }

    onNewWindowRequested: function(request) {
      var url = String(request.requestedUrl)
      var dialog = request.destination === WebEngineNewWindowRequest.InNewDialog
      if (dialog || win.isSignInOrigin(url)) {
        var popup = authWindow.createObject(win, { profile: profile, background: win.color, host: win })
        if (popup) {
          request.openIn(popup.view)
          popup.show()
          return
        }
      }
      Qt.openUrlExternally(request.requestedUrl)
    }

    onFullScreenRequested: function(request) {
      request.accept()
      if (request.toggleOn) {
        win.windowedVisibility = win.visibility
        win.visibility = Window.FullScreen
      } else {
        win.visibility = win.windowedVisibility === Window.FullScreen ? Window.Windowed : win.windowedVisibility
      }
    }

    onRenderProcessTerminated: function(terminationStatus, exitCode) {
      if (terminationStatus !== WebEngineView.NormalTerminationStatus) reloadTimer.restart()
    }
  }
}
