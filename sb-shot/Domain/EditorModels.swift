import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case line
    case arrow
    case rectangle
    case ellipse
    case text
    case pencil

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .pencil: return "pencil"
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
