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
        case .line(let start, let end):
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()

        case .arrow(let start, let end):
            drawArrow(start: start, end: end, style: annotation.style, in: context)

        case .rectangle(let rect):
            if annotation.style.fill {
                context.setFillColor(nsColor.withAlphaComponent(0.2).cgColor)
                context.fill(rect)
            }
            context.stroke(rect)

        case .ellipse(let rect):
            if annotation.style.fill {
                context.setFillColor(nsColor.withAlphaComponent(0.2).cgColor)
                context.fillEllipse(in: rect)
            }
            context.strokeEllipse(in: rect)

        case .text(let content, let origin):
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(annotation.style.lineWidth * 4, 14), weight: .semibold),
                .foregroundColor: nsColor
            ]
            (content as NSString).draw(at: origin, withAttributes: attrs)

        case .freehand(let points):
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

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(style.lineWidth * 4.5, 12)
        let spread = CGFloat.pi / 7

        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )

        context.beginPath()
        context.move(to: end)
        context.addLine(to: p1)
        context.move(to: end)
        context.addLine(to: p2)
        context.strokePath()
    }
}
