import QtQuick
import QtQuick.Window
import QtWebEngine
import "Theme.js" as Theme
import "WebAuth.js" as WebAuth
import "Media.js" as Media

// The Teams window. The real Teams web client runs in a WebEngineView; this
// file owns everything around it: the persistent profile, the Omarchy theme
// stylesheet and its live reload, desktop notifications, downloads, sign-in
// popups, the reload that keeps a long-running page from growing without
// bound, the status file the bar widget reads, and the socket commands the
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
  // MiB the Teams page may reach before it is reloaded in the background; 0 never.
  readonly property int memoryLimit: settings.memoryLimit === undefined ? 2048 : Math.max(0, Number(settings.memoryLimit) || 0)

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

  // Out of sight: hidden, or on a workspace Hyprland is not showing.
  property bool exposed: true
  readonly property bool concealed: !win.visible || !exposed
  property real concealedSince: 0
  property int pageMemory: -1
  // What this account's page takes once it has settled after a load, and the
  // limit that follows from it; see checkMemory().
  property int pageBaseline: -1
  property real pageLoadedAt: 0
  readonly property int effectiveLimit: memoryLimit <= 0 ? 0 : Math.max(memoryLimit, Math.round(pageBaseline * 1.5))
  readonly property int baselineDelayMs: 10 * 60 * 1000
  property real lastRecycle: 0
  property bool recycling: false
  property int recyclePid: 0
  // A page must stay out of sight this long before it is reloaded, so a
  // window someone just hid for a moment is never pulled from under them.
  readonly property int recycleIdleMs: 10 * 60 * 1000
  readonly property int recycleSpacingMs: 60 * 60 * 1000
  // Past this the page is not left to grow until it is out of sight: what
  // the renderer and this process hold together has gone far beyond anything
  // a normal session reaches, and the machine is what runs out next.
  readonly property int hardLimit: memoryLimit <= 0 ? 0 : Math.max(8192, 2 * effectiveLimit)
  readonly property int rescueSpacingMs: 2 * 60 * 1000
  property int hostMemory: -1
  property bool sharing: false
  property real lastRescue: 0
  // Over the hard limit in a call: reloaded once the call is over.
  property bool overdue: false
  property bool hostWarned: false
  // Set once this process has shared the screen. When a share ends,
  // Chromium's PipeWire capturer terminates the EGL display it shares with
  // the GPU thread, which in QtWebEngine runs in this very process (in Chrome
  // it is a process of its own). Every frame after that fails to get a sync
  // object, and discarding the page or shutting down dies with SIGTRAP. So
  // from then on a reload is a restart, and quitting skips the teardown.
  property bool captured: false

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
    } else if (captured) {
      close.accepted = false
      win.quit()
    }
  }
  onVisibleChanged: statusTimer.restart()
  onConcealedChanged: {
    concealedSince = concealed ? Date.now() : 0
    if (!concealed) revive()
  }
  onActiveChanged: statusTimer.restart()
  onWidthChanged: geometryTimer.restart()
  onHeightChanged: geometryTimer.restart()
  onThemeEnabledChanged: if (ready) rebuildCss()
  onFontFamilyChanged: if (ready) rebuildCss()

  Component.onCompleted: {
    installWebAuthScript()
    installMediaScript()
    Sys.watchExposure(win)
    loadSettings()
    restoreGeometry()
    loadTheme()
    refreshRounding()
    Sys.watch(colorsPath)
    Sys.watch(omarchyState)
    Sys.watch(settingsPath)
    Sys.watch(configDir)
    ready = true
    view.url = settings.url || defaultUrl
    if (startUrl.length > 0) openLink(startUrl)
    pageLoadedAt = Date.now()
    writeStatus()
    memoryRecheck.restart()
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

  // Counts the page's live microphone, camera and screen tracks, so the
  // background reload can tell a call from an idle page. See Media.js.
  function installMediaScript() {
    var script = WebEngine.script()
    script.name = "omateams-media"
    script.sourceCode = Media.pageScript()
    script.injectionPoint = WebEngineScript.DocumentCreation
    script.worldId = WebEngineScript.MainWorld
    script.runOnSubframes = false
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
      memory: pageMemory,
      hostMemory: hostMemory,
      sharing: sharing,
      memoryBaseline: pageBaseline,
      memoryLimit: effectiveLimit,
      lastReload: lastRecycle,
      reloading: recycling,
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

  // Hyprland suspends a window whose workspace is not on screen. When it comes
  // back, Qt draws the scene again but Chromium sends no new frame until the
  // page changes, so the view stays black until the next click or keypress.
  // A one-pixel change on the next animation frame makes it paint.
  function repaintPage() {
    view.runJavaScript(
      "requestAnimationFrame(function () {"
      + " var d = document.getElementById('omateams-repaint');"
      + " if (!d) { d = document.createElement('div'); d.id = 'omateams-repaint';"
      + "   d.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;background:#000;pointer-events:none;z-index:2147483647';"
      + "   (document.body || document.documentElement).appendChild(d); }"
      + " d.style.opacity = d.style.opacity === '0.01' ? '0.02' : '0.01';"
      + "})")
  }

  // ------------------------------------------------------------ memory
  // Teams never lets go of what a long session piles up: after days in the
  // background its page holds several GiB, where a fresh one needs a few
  // hundred MiB. A browser tab gets reloaded or discarded now and then; this
  // window may run hidden for weeks, so it does that itself, and only while
  // nobody is looking and no call is going on.
  //
  // How big a fresh page is depends on the account: a busy tenant starts at
  // over 2 GiB where a small one needs a few hundred MiB. So the page is
  // measured once it has settled, and reloading starts only at half as much
  // again on top, or at memoryLimit if that is higher; anything else would
  // reload a page that cannot get any smaller.
  function checkMemory() {
    if (recycling) return
    pageMemory = Sys.processMemory(view.renderProcessPid)
    hostMemory = Sys.processMemory(Sys.pid())
    if (pageBaseline < 0 && pageMemory > 0 && Date.now() - pageLoadedAt >= baselineDelayMs)
      pageBaseline = pageMemory
    statusTimer.restart()
    if (hardLimit > 0 && pageMemory + hostMemory > hardLimit) { rescue(); return }
    if (effectiveLimit <= 0 || pageBaseline < 0 || pageMemory <= effectiveLimit) return
    if (!concealed || win.active || Date.now() - concealedSince < recycleIdleMs) return
    // A limit set below what a fresh Teams needs must not turn into a loop.
    if (Date.now() - lastRecycle < recycleSpacingMs) return
    if (view.recentlyAudible || view.loading) return
    view.runJavaScript("window.__omateamsInCall ? window.__omateamsInCall() : false", function(inCall) {
      if (inCall !== true && win.concealed && !win.active) win.recycle()
    })
  }

  // Memory past the hard limit is dealt with at once, whether or not the
  // window is in sight. A screen share is ended, since that is where Teams
  // has been seen to run away, and the call goes on without it; a call is
  // never dropped, the page is reloaded once it is over; anything else is
  // reloaded right away.
  function rescue() {
    if (Date.now() - lastRescue < rescueSpacingMs) return
    lastRescue = Date.now()
    view.runJavaScript("window.__omateamsSharing ? [window.__omateamsSharing(), window.__omateamsInCall()] : [false, false]", function(state) {
      var used = gib(pageMemory + hostMemory)
      if (state && state[0]) {
        view.runJavaScript("window.__omateamsStopSharing()")
        sharing = false
        memoryNotice("Screen sharing stopped",
          "Teams had grown to " + used + " GiB while sharing your screen. The call goes on; share again to carry on.")
      } else if (state && state[1]) {
        if (!overdue) memoryNotice("Teams is using " + used + " GiB",
          "It will be reloaded as soon as the call is over.")
        overdue = true
      } else if (pageMemory > effectiveLimit) {
        memoryNotice("Teams reloaded", "It had grown to " + used + " GiB.")
        recycle()
      } else if (!hostWarned) {
        // The page is not what grew, so a reload would not free anything.
        hostWarned = true
        memoryNotice("Teams is using " + used + " GiB",
          "Most of it is held by the window process. Restart it with: omateams quit && omateams")
      }
    })
  }

  function gib(mib) { return (mib / 1024).toFixed(1) }

  function memoryNotice(title, body) {
    Sys.run("notify-send", ["-a", "Microsoft Teams", "-i", "omateams", "-u", "critical", title, body])
  }

  // Media.js reports when a screen share starts and ends.
  function reportMedia(message) {
    message = String(message)
    if (message.indexOf(Media.MARKER) !== 0) return
    var on = message.slice(Media.MARKER.length) === "on"
    if (on === sharing) return
    sharing = on
    if (on) captured = true
    if (on) memoryRecheck.restart()
    statusTimer.restart()
  }

  // The page is discarded and brought back once its renderer process has
  // ended, so the new page starts in a fresh process and the old one's memory
  // goes back to the system. A plain reload keeps the process and with it
  // nearly all of that memory. Chromium refuses to discard a page that is
  // shown, so the view is taken off screen meanwhile; the window is out of
  // sight anyway, and showing it brings the page back at once.
  function recycle() {
    if (recycling) return
    if (captured) { restart(); return }
    lastRecycle = Date.now()
    recyclePid = view.renderProcessPid
    recycling = true
    view.visible = false
    view.lifecycleState = WebEngineView.LifecycleState.Discarded
    if (view.lifecycleState !== WebEngineView.LifecycleState.Discarded) {
      view.visible = true
      recycling = false
      view.reload()
      pageBaseline = -1
      pageLoadedAt = Date.now()
    } else {
      reviveTimer.restart()
    }
    statusTimer.restart()
  }

  function revive() {
    if (!recycling) return
    reviveTimer.stop()
    recycling = false
    overdue = false
    hostWarned = false
    sharing = false
    view.lifecycleState = WebEngineView.LifecycleState.Active
    view.visible = true
    pageBaseline = -1
    pageLoadedAt = Date.now()
    memoryRecheck.restart()
    statusTimer.restart()
  }

  function restoreGeometry() {
    var s = safeJson(Sys.readFile(windowStatePath))
    if (!s) return
    if (Number(s.width) >= minimumWidth) win.width = Number(s.width)
    if (Number(s.height) >= minimumHeight) win.height = Number(s.height)
  }

  function handleCommand(connection, line) {
    var cmd = line.split(/\s+/)[0]
    var arg = String(line).slice(cmd.length).trim()
    switch (cmd) {
    case "open": openLink(arg); Sys.reply(connection, "ok"); break
    case "show": showWindow(); Sys.reply(connection, "ok"); break
    case "hide": win.hide(); Sys.reply(connection, "ok"); break
    case "toggle":
      if (win.visible) win.hide(); else showWindow()
      Sys.reply(connection, "ok")
      break
    case "status": Sys.reply(connection, JSON.stringify(statusObject())); break
    case "reload": recycle(); Sys.reply(connection, "ok"); break
    case "reload-theme": loadTheme(); refreshRounding(); Sys.reply(connection, "ok"); break
    case "quit": Sys.reply(connection, "ok"); quit(); break
    default: Sys.reply(connection, "unknown command: " + cmd)
    }
  }

  // A meeting or chat link handed over by another app (Omaoutlook, the
  // desktop's msteams: handler). Teams links load in the window; an msteams:
  // deep link is the same path on the web client.
  function openLink(url) {
    var u = String(url || "")
    if (/^msteams:/i.test(u)) u = "https://teams.microsoft.com" + u.replace(/^msteams:\/*/i, "/")
    showWindow()
    if (isTeamsOrigin(u)) {
      if (!routeDeepLink(u)) view.url = u
    } else if (u.length > 0) Qt.openUrlExternally(u)
  }

  // Loading a /l/ deep link (a meeting join, chat or channel link) reloads the
  // whole client before it shows the lobby. Teams' own launcher ends on
  // /v2/#/l/... instead, and the running app handles that hash in place, so
  // hand an already loaded client the same hash. Returns false when the link
  // has to load as a page: no /l/ path, or no client loaded yet.
  property string pendingDeepLink: ""

  function routeDeepLink(url) {
    var route = deepLinkRoute(url)
    if (!route || view.loading
        || !hostMatches(hostOf(view.url), ["teams.cloud.microsoft", "teams.microsoft.com", "teams.live.com"]))
      return false
    pendingDeepLink = url
    view.runJavaScript("location.hash = " + JSON.stringify(route) + ";")
    deepLinkCheck.restart()
    return true
  }

  // "https://teams.microsoft.com/l/meetup-join/19%3a...%40thread.v2/0?context=..."
  // -> "#/l/meetup-join/19:...@thread.v2/0?context=...&anon=true", the form
  // the launcher hands the client.
  function deepLinkRoute(url) {
    var m = String(url).match(/^https:\/\/[^\/]+(\/l\/[^?#]+)(\?[^#]*)?/i)
    if (!m) return ""
    var path = m[1]
    try { path = decodeURIComponent(path) } catch (e) {}
    var query = m[2] || ""
    if (/^\/l\/meetup-join\//i.test(path)) query += (query ? "&" : "?") + "anon=true"
    return "#" + path + query
  }

  function quit() {
    quitting = true
    writeStatus()
    if (captured) Sys.exitNow(0)
    Qt.quit()
  }

  // Starts a fresh process once this one is gone, shown or hidden as the
  // window is now, then leaves; the sign-in lives in the profile on disk.
  function restart() {
    lastRecycle = Date.now()
    quitting = true
    writeStatus()
    Sys.run("sh", ["-c", 'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec "$0" "$2"',
      Sys.executable(), String(Sys.pid()), win.visible ? "show" : "--hidden"])
    Sys.exitNow(0)
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
    function onExposureChanged(window, exposed) {
      if (window !== win) return
      win.exposed = exposed
      if (exposed) win.repaintPage()
    }
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
  // The client clears the hash once it has routed it. A hash still there
  // means this client ignored it, so load the link as a page after all.
  Timer {
    id: deepLinkCheck
    interval: 4000
    onTriggered: {
      var link = win.pendingDeepLink
      win.pendingDeepLink = ""
      if (!link) return
      view.runJavaScript("location.hash", function (hash) {
        if (String(hash || "").indexOf("#/l/") === 0) view.url = link
      })
    }
  }
  // Waits for the discarded page's renderer to exit, for half a minute at most.
  Timer {
    id: reviveTimer
    interval: 1000
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: if (++ticks >= 30 || Sys.processMemory(win.recyclePid) < 0) win.revive()
  }
  // Every few seconds while the screen is shared, where Teams can grow by
  // gigabytes a minute; every five minutes otherwise.
  Timer { id: memoryTimer; interval: win.sharing ? 10 * 1000 : 5 * 60 * 1000; repeat: true; running: true; onTriggered: win.checkMemory() }
  // Reads the size of the fresh page once it has settled after a reload.
  Timer { id: memoryRecheck; interval: 90 * 1000; onTriggered: win.checkMemory() }

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
    onJavaScriptConsoleMessage: function(level, message) { win.reportWebAuth(message); win.reportMedia(message) }
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
