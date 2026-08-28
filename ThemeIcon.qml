import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
  id: root

  property color color: Color.foreground
  property color urgentColor: Color.urgent
  property real iconSize: Style.font.icon

  // Item already supplies the public string `state` property.
  state: "disconnected"
  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  readonly property bool urgent: state === "warning" || state === "error"
  readonly property color stroke: urgent ? urgentColor : color
  readonly property color clear: Qt.rgba(stroke.r, stroke.g, stroke.b, 0)
  readonly property real line: Math.max(1, iconSize * 0.085)

  Shape {
    anchors.fill: parent
    layer.enabled: true
    layer.samples: 4
    opacity: root.state === "disconnected" ? 0.64 : 1

    ShapePath {
      fillColor: root.clear
      strokeColor: root.stroke
      strokeWidth: root.line
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: root.width * 0.50
      startY: root.height * 0.10
      PathLine { x: root.width * 0.82; y: root.height * 0.22 }
      PathLine { x: root.width * 0.78; y: root.height * 0.60 }
      PathCubic {
        x: root.width * 0.50
        y: root.height * 0.90
        control1X: root.width * 0.75
        control1Y: root.height * 0.76
        control2X: root.width * 0.61
        control2Y: root.height * 0.86
      }
      PathCubic {
        x: root.width * 0.22
        y: root.height * 0.60
        control1X: root.width * 0.39
        control1Y: root.height * 0.86
        control2X: root.width * 0.25
        control2Y: root.height * 0.76
      }
      PathLine { x: root.width * 0.18; y: root.height * 0.22 }
      PathLine { x: root.width * 0.50; y: root.height * 0.10 }
    }

    ShapePath {
      fillColor: root.clear
      strokeColor: root.state === "connected" ? root.stroke : root.clear
      strokeWidth: root.line
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: root.width * 0.31
      startY: root.height * 0.51
      PathLine { x: root.width * 0.45; y: root.height * 0.65 }
      PathLine { x: root.width * 0.70; y: root.height * 0.36 }
    }

    ShapePath {
      fillColor: root.clear
      strokeColor: root.state === "disconnected" ? root.stroke : root.clear
      strokeWidth: root.line
      capStyle: ShapePath.RoundCap
      startX: root.width * 0.32
      startY: root.height * 0.68
      PathLine { x: root.width * 0.68; y: root.height * 0.32 }
    }

    ShapePath {
      fillColor: root.clear
      strokeColor: root.state === "connecting" ? root.stroke : root.clear
      strokeWidth: root.line
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: root.width * 0.29
      startY: root.height * 0.44
      PathLine { x: root.width * 0.67; y: root.height * 0.44 }
      PathLine { x: root.width * 0.57; y: root.height * 0.34 }
      PathMove { x: root.width * 0.71; y: root.height * 0.60 }
      PathLine { x: root.width * 0.33; y: root.height * 0.60 }
      PathLine { x: root.width * 0.43; y: root.height * 0.70 }
    }

    ShapePath {
      fillColor: root.clear
      strokeColor: root.state === "warning" ? root.stroke : root.clear
      strokeWidth: root.line
      capStyle: ShapePath.RoundCap
      startX: root.width * 0.50
      startY: root.height * 0.31
      PathLine { x: root.width * 0.50; y: root.height * 0.57 }
      PathMove { x: root.width * 0.50; y: root.height * 0.70 }
      PathLine { x: root.width * 0.50; y: root.height * 0.70 }
    }

    ShapePath {
      fillColor: root.clear
      strokeColor: root.state === "error" ? root.stroke : root.clear
      strokeWidth: root.line
      capStyle: ShapePath.RoundCap
      startX: root.width * 0.35
      startY: root.height * 0.35
      PathLine { x: root.width * 0.65; y: root.height * 0.65 }
      PathMove { x: root.width * 0.65; y: root.height * 0.35 }
      PathLine { x: root.width * 0.35; y: root.height * 0.65 }
    }
  }
}
