import QtQuick
import qs.Commons

Item {
  id: root

  property color color: Color.foreground
  property color urgentColor: Color.urgent
  // `iconSize` is the target glyph *height*. The width follows the padlock
  // silhouette (roughly 3:4) so the mark keeps its aspect ratio instead of
  // being boxed into a square that reads taller than the bar's text glyphs.
  property real iconSize: Style.font.icon
  property bool locked: state === "connected" || state === "connecting"
  readonly property real glyphAspect: 0.75

  // Item already supplies the public string `state` property.
  state: "disconnected"
  implicitWidth: width
  implicitHeight: height
  width: Math.max(1, Math.round(iconSize * glyphAspect))
  height: iconSize

  readonly property bool urgent: state === "warning" || state === "error"
  readonly property color fill: urgent ? urgentColor : color

  Item {
    id: glyph

    width: 16
    height: 16
    anchors.centerIn: parent
    scale: root.height / 16
    opacity: root.locked ? 1 : 0.55
    layer.enabled: true
    layer.samples: 4

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Rectangle {
      x: root.locked ? 2 : 0
      y: 7
      width: 12
      height: 9
      radius: 1
      color: root.fill
      antialiasing: true

      Behavior on x {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      x: root.locked ? 4 : 8
      y: 0
      width: 8
      height: 2
      radius: 1
      color: root.fill
      antialiasing: true

      Behavior on x {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      x: root.locked ? 4 : 8
      y: 1
      width: 2
      height: 7
      radius: 1
      color: root.fill
      antialiasing: true

      Behavior on x {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Rectangle {
      x: root.locked ? 10 : 14
      y: 1
      width: 2
      height: 7
      radius: 1
      color: root.fill
      antialiasing: true

      Behavior on x {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}
