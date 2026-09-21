import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One icon, one number, one click. The service owns the state; the widget is
// what hands the plugin settings over and what the click lands on.
BarWidget {
  id: root

  moduleName: "omateams"

  readonly property var teams: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("omateams") : null
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property bool drawsIcon: setting("showBarIcon", true) !== false
  readonly property bool showCount: setting("showCount", true) !== false
  readonly property int unread: teams ? teams.unread : 0
  readonly property bool activity: !!teams && teams.activity
  readonly property bool running: !!teams && teams.running
  readonly property bool countVisible: drawsIcon && showCount && unread > 0 && !vertical

  // The shell hands settings to the bar widget, not to the service, so the
  // widget forwards them; the service writes them where the window reads them.
  function pushSettings() {
    if (teams && typeof teams.applySettings === "function") teams.applySettings(settings)
  }
  onSettingsChanged: pushSettings()
  onTeamsChanged: pushSettings()
  Component.onCompleted: pushSettings()

  visible: drawsIcon
  implicitWidth: drawsIcon ? row.implicitWidth : 0
  implicitHeight: drawsIcon ? row.implicitHeight : 0

  Row {
    id: row
    anchors.centerIn: parent
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      tooltipText: root.teams ? root.teams.tooltip : "Microsoft Teams"

      readonly property color glyphColor: root.running ? root.foreground : Qt.darker(root.foreground, 1.55)

      iconComponent: Component {
        Item {
          TeamsIcon {
            anchors.centerIn: parent
            iconSize: Style.space(12)
            color: button.glyphColor
            badgeColor: Color.accent
            dot: root.unread > 0 || root.activity
            crossed: !root.running
          }
        }
      }

      onPressed: function(buttonCode) {
        if (!root.teams) return
        if (buttonCode === Qt.LeftButton) root.teams.toggle()
        else if (buttonCode === Qt.RightButton) root.teams.show()
        else if (buttonCode === Qt.MiddleButton) root.teams.refresh()
      }
    }

    Text {
      visible: root.countVisible
      anchors.verticalCenter: parent.verticalCenter
      text: root.unread > 99 ? "99+" : String(root.unread)
      color: root.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
      rightPadding: Style.space(6)
    }
  }
}
