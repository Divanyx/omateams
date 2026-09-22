import QtQuick
import QtQuick.Window
import QtWebEngine

// A dialog for the sign-in popups Microsoft's login opens with window.open:
// it shares the main profile so the resulting session lands in the same
// cookie jar, and it closes itself when the login script calls window.close().
Window {
  id: root

  property alias view: authView
  property var profile: null
  property color background: "#101315"
  // The main window, which owns the theme and the security-key dialog.
  property var host: null

  width: 560
  height: 720
  minimumWidth: 360
  minimumHeight: 400
  flags: Qt.Dialog
  title: authView.title.length > 0 ? authView.title : "Sign in"
  color: background

  onClosing: Qt.callLater(root.destroy)

  WebEngineView {
    id: authView
    anchors.fill: parent
    profile: root.profile
    settings.javascriptCanOpenWindows: true
    settings.javascriptCanAccessClipboard: true

    onJavaScriptConsoleMessage: function(level, message) { if (root.host) root.host.reportWebAuth(message) }

    onWindowCloseRequested: root.close()
    // Redirect chains inside the login flow stay in this dialog.
    onNewWindowRequested: function(request) { request.openIn(authView) }
    onPermissionRequested: function(permission) { permission.deny() }
    // Passkeys and security keys are used right here, on the sign-in page.
    onWebAuthUxRequested: function(request) {
      if (root.host) root.host.showWebAuthUx(request, root)
      else request.cancel()
    }
  }
}
