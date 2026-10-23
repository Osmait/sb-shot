import AppKit
import SwiftUI

struct AnnotationRenderer {
    func render(baseImage: NSImage, annotations: [EditorAnnotation]) -> NSImage {
        let output = NSImage(size: baseImage.size)
        output.lockFocusFlipped(true)

        baseImage.draw(in: CGRect(origin: .zero, size: baseImage.size))

        guard let context = NSGraphicsContext.current?.cgContext else {
            output.unlockFocus()
            return output
        }

        for annotation in annotations {
            draw(annotation: annotation, in: context)
        }

        output.unlockFocus()
        return output
    }

    private func draw(annotation: EditorAnnotation, in context: CGContext) {
        let nsColor = NSColor(annotation.style.color)
        context.setStrokeColor(nsColor.cgColor)
        context.setLineWidth(annotation.style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case let .line(start, end):
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()

        case let .arrow(start, end):
            drawArrow(start: start, end: end, style: annotation.style, in: context)

        case let .rectangle(rect):
            if annotation.style.fill {
                context.setFillColor(nsColor.withAlphaComponent(0.2).cgColor)
                context.fill(rect)
            }
            context.stroke(rect)

        case let .ellipse(rect):
            if annotation.style.fill {
                context.setFillColor(nsColor.withAlphaComponent(0.2).cgColor)
                context.fillEllipse(in: rect)
            }
            context.strokeEllipse(in: rect)

        case let .text(content, origin):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(annotation.style.lineWidth * 4, 14), weight: .semibold),
                .foregroundColor: nsColor,
            ]
            (content as NSString).draw(at: origin, withAttributes: attrs)

        case let .freehand(points):
            guard let first = points.first else { return }
            context.beginPath()
            context.move(to: first)
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }
    }

    private func drawArrow(start: CGPoint, end: CGPoint, style: AnnotationStyle, in context: CGContext) {
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let head = ArrowHead(from: start, to: end, lineWidth: style.lineWidth)

        context.beginPath()
        context.move(to: head.tip)
        context.addLine(to: head.left)
        context.move(to: head.tip)
        context.addLine(to: head.right)
        context.strokePath()
    }
}
