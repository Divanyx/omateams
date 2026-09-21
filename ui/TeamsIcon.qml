import QtQuick
import qs.Commons

// Two overlapping speech bubbles drawn in QML, so the bar icon stays sharp at
// every scale and picks up the bar's colors instead of shipping an image.
Item {
  id: root

  property real iconSize: 16
  property color color: Color.foreground
  property color badgeColor: Color.accent
  property bool dot: false
  property bool crossed: false

  implicitWidth: iconSize
  implicitHeight: iconSize
  opacity: crossed ? 0.55 : 1

  // Back bubble: outlined.
  Rectangle {
    x: 0
    y: root.iconSize * 0.08
    width: root.iconSize * 0.68
    height: root.iconSize * 0.52
    radius: height * 0.3
    color: "transparent"
    border.color: root.color
    border.width: Math.max(1, root.iconSize * 0.1)
  }
  Rectangle {
    // Its tail.
    x: root.iconSize * 0.1
    y: root.iconSize * 0.5
    width: root.iconSize * 0.16
    height: root.iconSize * 0.16
    color: root.color
    rotation: 45
    transformOrigin: Item.Center
  }

  // Front bubble: filled, offset to the lower right.
  Rectangle {
    x: root.iconSize * 0.36
    y: root.iconSize * 0.4
    width: root.iconSize * 0.62
    height: root.iconSize * 0.46
    radius: height * 0.3
    color: root.color
  }
  Rectangle {
    x: root.iconSize * 0.72
    y: root.iconSize * 0.76
    width: root.iconSize * 0.14
    height: root.iconSize * 0.14
    color: root.color
    rotation: 45
    transformOrigin: Item.Center
  }

  // Unread marker.
  Rectangle {
    visible: root.dot
    x: root.iconSize * 0.7
    y: 0
    width: root.iconSize * 0.34
    height: width
    radius: width / 2
    color: root.badgeColor
  }

  // Not running: a bar across, like a muted speaker.
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: root.iconSize * 1.25
    height: Math.max(1, root.iconSize * 0.1)
    color: root.color
    rotation: -45
  }
}
