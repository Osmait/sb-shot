import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case line
    case arrow
    case rectangle
    case ellipse
    case text
    case pencil

    var id: String {
        rawValue
    }

    var iconName: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .pencil: "pencil"
        }
    }
}

struct AnnotationStyle {
    var color: Color
    var lineWidth: CGFloat
    var fill: Bool
}

struct EditorAnnotation: Identifiable {
    enum Kind {
        case line(start: CGPoint, end: CGPoint)
        case arrow(start: CGPoint, end: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case text(content: String, origin: CGPoint)
        case freehand(points: [CGPoint])
    }

    let id: UUID
    var kind: Kind
    var style: AnnotationStyle

    init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }
}
