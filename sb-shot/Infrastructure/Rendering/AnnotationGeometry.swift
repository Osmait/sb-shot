import AppKit

nonisolated enum AnnotationHandle: Hashable, CaseIterable, Sendable {
    case start
    case end
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

nonisolated enum AnnotationMetrics {
    static let textPadding = CGSize(width: 10, height: 5)

    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .bold)
    }

    static func textSize(_ content: String, fontSize: CGFloat) -> CGSize {
        let attributed = NSAttributedString(
            string: content.isEmpty ? " " : content,
            attributes: [.font: textFont(size: fontSize)]
        )
        let size = attributed.boundingRect(
            with: CGSize(width: 10000, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Rectangulo que ocupa un texto (incluye el fondo si lo tiene). `origin` es la esquina superior izquierda.
    static func textRect(content: String, origin: CGPoint, style: AnnotationStyle) -> CGRect {
        let size = textSize(content, fontSize: style.fontSize)
        guard style.textBackground else {
            return CGRect(origin: origin, size: size)
        }
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: size.width + textPadding.width * 2,
            height: size.height + textPadding.height * 2
        )
    }

    static func counterRadius(lineWidth: CGFloat) -> CGFloat {
        11 + lineWidth * 1.5
    }

    static func highlightWidth(lineWidth: CGFloat) -> CGFloat {
        max(lineWidth * 5, 16)
    }
}

nonisolated extension CGRect {
    static func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func point(for handle: AnnotationHandle) -> CGPoint {
        switch handle {
        case .topLeft, .start: CGPoint(x: minX, y: minY)
        case .topRight: CGPoint(x: maxX, y: minY)
        case .bottomLeft: CGPoint(x: minX, y: maxY)
        case .bottomRight, .end: CGPoint(x: maxX, y: maxY)
        }
    }

    func resized(handle: AnnotationHandle, to point: CGPoint) -> CGRect {
        let opposite = switch handle {
        case .topLeft, .start: CGPoint(x: maxX, y: maxY)
        case .topRight: CGPoint(x: minX, y: maxY)
        case .bottomLeft: CGPoint(x: maxX, y: minY)
        case .bottomRight, .end: CGPoint(x: minX, y: minY)
        }
        return .spanning(opposite, point)
    }

    static let cornerHandles: [AnnotationHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

private nonisolated func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }

    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
}

private nonisolated func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
    guard let first = points.first else { return .infinity }
    guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
    return zip(points, points.dropFirst())
        .map { distance(from: point, toSegment: $0, $1) }
        .min() ?? .infinity
}

nonisolated extension EditorAnnotation {
    var bounds: CGRect {
        switch kind {
        case let .line(start, end), let .arrow(start, end):
            return CGRect.spanning(start, end).insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case let .rectangle(rect), let .ellipse(rect), let .obfuscate(rect), let .spotlight(rect):
            return rect
        case let .text(content, origin):
            return AnnotationMetrics.textRect(content: content, origin: origin, style: style)
        case let .counter(center):
            let radius = AnnotationMetrics.counterRadius(lineWidth: style.lineWidth)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case let .freehand(points), let .highlight(points):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case let .line(start, end), let .arrow(start, end):
            return distance(from: point, toSegment: start, end) <= style.lineWidth / 2 + tolerance

        case let .rectangle(rect):
            if style.fill {
                return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            }
            let outer = rect.insetBy(dx: -tolerance - style.lineWidth / 2, dy: -tolerance - style.lineWidth / 2)
            let inner = rect.insetBy(dx: tolerance + style.lineWidth / 2, dy: tolerance + style.lineWidth / 2)
            return outer.contains(point) && (inner.isEmpty || !inner.contains(point))

        case let .ellipse(rect):
            let a = max(rect.width / 2, 1)
            let b = max(rect.height / 2, 1)
            let nx = (point.x - rect.midX) / a
            let ny = (point.y - rect.midY) / b
            let radius = sqrt(nx * nx + ny * ny)
            if style.fill {
                return radius <= 1 + tolerance / min(a, b)
            }
            return abs(radius - 1) * min(a, b) <= tolerance + style.lineWidth / 2

        case let .obfuscate(rect), let .spotlight(rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .text, .counter:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case let .freehand(points):
            return distance(from: point, toPolyline: points) <= style.lineWidth / 2 + tolerance

        case let .highlight(points):
            return distance(from: point, toPolyline: points) <= AnnotationMetrics.highlightWidth(lineWidth: style.lineWidth) / 2 + tolerance
        }
    }

    var handles: [AnnotationHandle: CGPoint] {
        switch kind {
        case let .line(start, end), let .arrow(start, end):
            [.start: start, .end: end]
        case let .rectangle(rect), let .ellipse(rect), let .obfuscate(rect), let .spotlight(rect):
            Dictionary(uniqueKeysWithValues: CGRect.cornerHandles.map { ($0, rect.point(for: $0)) })
        case .text, .counter, .freehand, .highlight:
            [:]
        }
    }

    func translated(by delta: CGSize) -> EditorAnnotation {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.width, y: point.y + delta.height)
        }

        var copy = self
        switch kind {
        case let .line(start, end): copy.kind = .line(start: move(start), end: move(end))
        case let .arrow(start, end): copy.kind = .arrow(start: move(start), end: move(end))
        case let .rectangle(rect): copy.kind = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .ellipse(rect): copy.kind = .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .obfuscate(rect): copy.kind = .obfuscate(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .spotlight(rect): copy.kind = .spotlight(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .text(content, origin): copy.kind = .text(content: content, origin: move(origin))
        case let .counter(center): copy.kind = .counter(center: move(center))
        case let .freehand(points): copy.kind = .freehand(points: points.map(move))
        case let .highlight(points): copy.kind = .highlight(points: points.map(move))
        }
        return copy
    }

    func resized(handle: AnnotationHandle, to point: CGPoint) -> EditorAnnotation {
        var copy = self
        switch kind {
        case let .line(start, end):
            copy.kind = handle == .start ? .line(start: point, end: end) : .line(start: start, end: point)
        case let .arrow(start, end):
            copy.kind = handle == .start ? .arrow(start: point, end: end) : .arrow(start: start, end: point)
        case let .rectangle(rect):
            copy.kind = .rectangle(rect.resized(handle: handle, to: point))
        case let .ellipse(rect):
            copy.kind = .ellipse(rect.resized(handle: handle, to: point))
        case let .obfuscate(rect):
            copy.kind = .obfuscate(rect.resized(handle: handle, to: point))
        case let .spotlight(rect):
            copy.kind = .spotlight(rect.resized(handle: handle, to: point))
        case .text, .counter, .freehand, .highlight:
            break
        }
        return copy
    }
}
