import QtQuick
import QtQuick.Window
import QtWebEngine
import "Theme.js" as Theme

// The security-key prompt. QtWebEngine hands the whole WebAuthn experience to
// the application: Chromium emits webAuthUxRequested and then waits for an
// answer -- a chosen account, a PIN, or a cancel. A window that ignores the
// signal leaves the request open until Chromium gives up on its own, well past
// the timeout the site asked for, with nothing on screen and every later
// WebAuthn call in that page failing with "a request is already pending".
// Which is why this dialog answers the request when it is simply closed too.
Window {
  id: root

  property var request: null
  property var pal: ({})
  property int radius: 8

  readonly property int uxState: request ? request.state : WebEngineWebAuthUxRequest.WebAuthUxState.NotStarted
  readonly property var pin: request ? request.pinRequest : null
  readonly property string rp: request ? String(request.relyingPartyId) : ""
  property bool answered: false

  readonly property color bg: pal.bg || "#101315"
  readonly property color card: pal.card || "#181c1e"
  readonly property color fg: pal.fg || "#cacccc"
  readonly property color fgDim: pal.fg3 || "#8b8f90"
  readonly property color accent: pal.accent || "#3b82f6"
  readonly property color onAccent: pal.onBrand || "#ffffff"
  readonly property color danger: pal.red || "#d13438"

  width: 420
  height: Math.max(220, body.implicitHeight + 2 * body.anchors.margins)
  minimumWidth: 360
  minimumHeight: 200
  flags: Qt.Dialog
  modality: Qt.WindowModal
  color: bg
  title: qsTr("Security key")

  onUxStateChanged: {
    if (uxState === WebEngineWebAuthUxRequest.WebAuthUxState.Completed
        || uxState === WebEngineWebAuthUxRequest.WebAuthUxState.Cancelled) {
      answered = true
      root.close()
    }
  }

  // Closing is a cancel: Chromium is still waiting, and nothing else will
  // ever tell it to stop.
  onClosing: {
    if (!answered && request) { answered = true; request.cancel() }
    Qt.callLater(root.destroy)
  }

  function heading() {
    switch (uxState) {
    case WebEngineWebAuthUxRequest.WebAuthUxState.SelectAccount:
      return qsTr("Choose an account")
    case WebEngineWebAuthUxRequest.WebAuthUxState.CollectPin:
      if (!pin) return qsTr("Security key PIN")
      if (pin.reason === WebEngineWebAuthUxRequest.PinEntryReason.Set) return qsTr("Set a PIN for your security key")
      if (pin.reason === WebEngineWebAuthUxRequest.PinEntryReason.Change) return qsTr("Change your security key PIN")
      return qsTr("Enter your security key PIN")
    case WebEngineWebAuthUxRequest.WebAuthUxState.FinishTokenCollection:
      return qsTr("Touch your security key")
    case WebEngineWebAuthUxRequest.WebAuthUxState.RequestFailed:
      return qsTr("Sign-in failed")
    default:
      return qsTr("Waiting for your security key")
    }
  }

  function detail() {
    switch (uxState) {
    case WebEngineWebAuthUxRequest.WebAuthUxState.SelectAccount:
      return qsTr("More than one account on this key can sign in to %1.").arg(rp)
    case WebEngineWebAuthUxRequest.WebAuthUxState.FinishTokenCollection:
      return qsTr("Confirm the sign-in to %1 on the key itself.").arg(rp)
    case WebEngineWebAuthUxRequest.WebAuthUxState.RequestFailed:
      return failureText()
    case WebEngineWebAuthUxRequest.WebAuthUxState.CollectPin:
      return ""
    default:
      return qsTr("Plug in your security key to sign in to %1.").arg(rp)
    }
  }

  // Passkeys held by the operating system or by a phone are not part of this:
  // a Chromium without a platform authenticator (every Linux build) and
  // without the hybrid transport UI can only talk to a key it can see.
  function failureText() {
    var R = WebEngineWebAuthUxRequest.RequestFailureReason
    switch (request ? request.requestFailureReason : -1) {
    case R.Timeout: return qsTr("The key did not answer in time.")
    case R.KeyNotRegistered: return qsTr("This key is not registered for %1.").arg(rp)
    case R.KeyAlreadyRegistered: return qsTr("This key is already registered for %1.").arg(rp)
    case R.SoftPinBlock: return qsTr("Too many wrong PINs. Unplug the key and plug it back in.")
    case R.HardPinBlock: return qsTr("The key is locked after too many wrong PINs and has to be reset.")
    case R.AuthenticatorRemovedDuringPinEntry: return qsTr("The key was removed while the PIN was being entered.")
    case R.AuthenticatorMissingResidentKeys: return qsTr("This key cannot store a sign-in for %1.").arg(rp)
    case R.AuthenticatorMissingUserVerification: return qsTr("This key has no PIN or fingerprint, which %1 requires.").arg(rp)
    case R.AuthenticatorMissingLargeBlob: return qsTr("This key does not support what %1 asked for.").arg(rp)
    case R.NoCommonAlgorithms: return qsTr("This key and %1 share no supported algorithm.").arg(rp)
    case R.StorageFull: return qsTr("The key is full. Remove a sign-in from it and try again.")
    case R.UserConsentDenied: return qsTr("The sign-in was refused on the key.")
    case R.WinUserCancelled: return qsTr("The sign-in was cancelled.")
    default: return qsTr("The key could not be used for %1.").arg(rp)
    }
  }

  function pinError() {
    if (!pin) return ""
    var E = WebEngineWebAuthUxRequest.PinEntryError
    switch (pin.error) {
    case E.InternalUvLocked: return qsTr("Fingerprint reading is locked. Use the PIN.")
    case E.WrongPin: return qsTr("Wrong PIN.")
    case E.TooShort: return qsTr("The PIN needs at least %1 characters.").arg(pin.minPinLength)
    case E.InvalidCharacters: return qsTr("The PIN contains characters the key does not accept.")
    case E.SameAsCurrentPin: return qsTr("The new PIN has to differ from the current one.")
    default: return ""
    }
  }

  function submitPin() {
    if (!request || pinField.text.length === 0) return
    request.setPin(pinField.text)
    pinField.text = ""
  }

  function chooseAccount(name) {
    if (request) request.setSelectedAccount(name)
  }

  component DialogButton: Rectangle {
    id: button
    property alias label: buttonText.text
    property bool primary: false
    signal clicked()
    width: Math.max(96, buttonText.implicitWidth + 28)
    height: 34
    radius: root.radius
    color: primary
      ? (buttonArea.containsMouse ? Qt.lighter(root.accent, 1.15) : root.accent)
      : (buttonArea.containsMouse ? Qt.lighter(root.card, 1.3) : root.card)
    Text {
      id: buttonText
      anchors.centerIn: parent
      color: button.primary ? root.onAccent : root.fg
      font.pixelSize: 13
    }
    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: button.clicked()
    }
  }

  Column {
    id: body
    anchors.fill: parent
    anchors.margins: 20
    spacing: 14

    Text {
      width: parent.width
      text: root.heading()
      color: root.fg
      font.pixelSize: 16
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Text {
      width: parent.width
      text: root.detail()
      color: root.uxState === WebEngineWebAuthUxRequest.WebAuthUxState.RequestFailed ? root.danger : root.fgDim
      font.pixelSize: 13
      wrapMode: Text.WordWrap
      visible: text.length > 0
    }

    // ----------------------------------------------------------- accounts
    Column {
      width: parent.width
      spacing: 6
      visible: root.uxState === WebEngineWebAuthUxRequest.WebAuthUxState.SelectAccount

      Repeater {
        model: root.request ? root.request.userNames : []
        delegate: Rectangle {
          id: account
          required property string modelData
          width: body.width
          height: 40
          radius: root.radius
          color: accountArea.containsMouse ? root.accent : root.card
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            elide: Text.ElideRight
            text: account.modelData
            color: accountArea.containsMouse ? root.onAccent : root.fg
            font.pixelSize: 13
          }
          MouseArea {
            id: accountArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.chooseAccount(account.modelData)
          }
        }
      }
    }

    // ---------------------------------------------------------------- pin
    Column {
      width: parent.width
      spacing: 8
      visible: root.uxState === WebEngineWebAuthUxRequest.WebAuthUxState.CollectPin

      Rectangle {
        width: parent.width
        height: 38
        radius: root.radius
        color: root.card
        border.width: pinField.activeFocus ? 1 : 0
        border.color: root.accent

        TextInput {
          id: pinField
          anchors.fill: parent
          anchors.leftMargin: 12
          anchors.rightMargin: 12
          verticalAlignment: TextInput.AlignVCenter
          echoMode: TextInput.Password
          passwordCharacter: "•"
          color: root.fg
          selectionColor: root.accent
          selectedTextColor: root.onAccent
          font.pixelSize: 14
          focus: root.visible && root.uxState === WebEngineWebAuthUxRequest.WebAuthUxState.CollectPin
          onAccepted: root.submitPin()
        }
      }

      Text {
        width: parent.width
        text: root.pinError()
        color: root.danger
        font.pixelSize: 12
        wrapMode: Text.WordWrap
        visible: text.length > 0
      }

      Text {
        width: parent.width
        text: root.pin && root.pin.remainingAttempts > 0
          ? qsTr("%1 attempts left before the key locks.").arg(root.pin.remainingAttempts)
          : ""
        color: root.fgDim
        font.pixelSize: 12
        visible: text.length > 0
      }
    }

    Item { width: 1; height: 1 }

    // ------------------------------------------------------------ buttons
    Row {
      anchors.right: parent.right
      spacing: 8

      DialogButton {
        label: qsTr("Cancel")
        onClicked: root.close()
      }

      DialogButton {
        label: qsTr("Try again")
        primary: true
        visible: root.uxState === WebEngineWebAuthUxRequest.WebAuthUxState.RequestFailed
        onClicked: if (root.request) root.request.retry()
      }

      DialogButton {
        label: qsTr("Continue")
        primary: true
        visible: root.uxState === WebEngineWebAuthUxRequest.WebAuthUxState.CollectPin
        onClicked: root.submitPin()
      }
    }
  }

  Shortcut { sequences: ["Escape"]; onActivated: root.close() }
}
