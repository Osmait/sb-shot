import AppKit
import SwiftUI

/// Distribucion del documento en el lienzo de salida: recorte, padding del fondo y desplazamiento de la imagen.
struct RenderLayout {
    let outputSize: CGSize
    /// Donde se dibuja la imagen (recortada) dentro del lienzo de salida.
    let contentRect: CGRect
    /// Parte visible de la imagen, en coordenadas de la imagen.
    let visibleRect: CGRect
    let background: BackgroundSettings?

    init(document: EditorDocument, imageSize: CGSize, applyCropAndBackground: Bool = true) {
        let fullRect = CGRect(origin: .zero, size: imageSize)
        let cropped = document.cropRect?.intersection(fullRect)
        let visible = applyCropAndBackground ? (cropped.flatMap { $0.isEmpty ? nil : $0 } ?? fullRect) : fullRect
        let background = applyCropAndBackground && document.background.isEnabled ? document.background : nil
        let padding = background?.padding ?? 0

        visibleRect = visible
        self.background = background

        // Con una proporcion fija el lienzo crece en un solo eje y la imagen queda centrada.
        var size = CGSize(width: visible.width + padding * 2, height: visible.height + padding * 2)
        if let ratio = background?.aspect.ratio {
            if size.width / max(size.height, 1) < ratio {
                size.width = (size.height * ratio).rounded()
            } else {
                size.height = (size.width / ratio).rounded()
            }
        }
        outputSize = size
        contentRect = CGRect(
            x: ((size.width - visible.width) / 2).rounded(),
            y: ((size.height - visible.height) / 2).rounded(),
            width: visible.width,
            height: visible.height
        )
    }

    private var offset: CGSize {
        CGSize(width: contentRect.minX - visibleRect.minX, height: contentRect.minY - visibleRect.minY)
    }

    func toOutput(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.width, y: point.y + offset.height)
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - offset.width, y: point.y - offset.height)
    }

    func toOutput(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: offset.width, dy: offset.height)
    }
}

/// Dibuja documentos del editor con CoreGraphics. Lo usan tanto el lienzo como la exportacion,
/// asi lo que se ve en pantalla coincide con la imagen final.
struct AnnotationRenderer {
    func render(document: EditorDocument, sources: RenderSources) -> NSImage {
        let layout = RenderLayout(document: document, imageSize: sources.pointSize)
        let scale = sources.pixelScale
        let width = max(Int((layout.outputSize.width * scale).rounded()), 1)
        let height = max(Int((layout.outputSize.height * scale).rounded()), 1)

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace.renderable(for: sources.base),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return NSImage(cgImage: sources.base, size: sources.pointSize)
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high

        draw(document: document, layout: layout, sources: sources, in: context)

        guard let output = context.makeImage() else {
            return NSImage(cgImage: sources.base, size: sources.pointSize)
        }
        return NSImage(cgImage: output, size: layout.outputSize)
    }

    /// Dibuja en un contexto con origen arriba-izquierda, en unidades del lienzo de salida.
    func draw(
        document: EditorDocument,
        layout: RenderLayout,
        sources: RenderSources,
        in context: CGContext,
        excludingAnnotationID: UUID? = nil
    ) {
        let unitScale = hypot(context.ctm.a, context.ctm.b)
        let cornerRadius = layout.background?.cornerRadius ?? 0
        let contentPath = CGPath(
            roundedRect: layout.contentRect,
            cornerWidth: min(cornerRadius, layout.contentRect.width / 2),
            cornerHeight: min(cornerRadius, layout.contentRect.height / 2),
            transform: nil
        )

        if let background = layout.background {
            drawBackground(background, size: layout.outputSize, in: context)

            if background.shadow {
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: 0, height: -12 * unitScale),
                    blur: 36 * unitScale,
                    color: NSColor.black.withAlphaComponent(0.4).cgColor
                )
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(contentPath)
                context.fillPath()
                context.restoreGState()
            }
        }

        context.saveGState()
        context.addPath(contentPath)
        context.clip()

        context.translateBy(
            x: layout.contentRect.minX - layout.visibleRect.minX,
            y: layout.contentRect.minY - layout.visibleRect.minY
        )

        let imageRect = CGRect(origin: .zero, size: sources.pointSize)
        drawUpright(sources.base, in: imageRect, context: context)

        let annotations = document.annotations.filter { $0.id != excludingAnnotationID }

        for annotation in annotations {
            if case let .obfuscate(rect) = annotation.kind, let effect = sources.image(for: annotation.style.obfuscation) {
                context.saveGState()
                context.clip(to: rect)
                drawUpright(effect, in: imageRect, context: context)
                context.restoreGState()
            }
        }

        drawSpotlights(annotations, imageRect: imageRect, in: context)

        let counterNumbers = Self.counterNumbers(in: document.annotations)
        for annotation in annotations {
            draw(annotation, counterNumber: counterNumbers[annotation.id], unitScale: unitScale, in: context)
        }

        context.restoreGState()
    }

    static func counterNumbers(in annotations: [EditorAnnotation]) -> [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for annotation in annotations {
            if case .counter = annotation.kind {
                numbers[annotation.id] = next
                next += 1
            }
        }
        return numbers
    }

    // MARK: - Private

    private func drawBackground(_ background: BackgroundSettings, size: CGSize, in context: CGContext) {
        let colors = background.preset.colors.map { NSColor($0).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }

        context.saveGState()
        context.addRect(CGRect(origin: .zero, size: size))
        context.clip()
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.restoreGState()
    }

    private func drawSpotlights(_ annotations: [EditorAnnotation], imageRect: CGRect, in context: CGContext) {
        let rects = annotations.compactMap { annotation -> CGRect? in
            if case let .spotlight(rect) = annotation.kind {
                return rect
            }
            return nil
        }
        guard !rects.isEmpty else { return }

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fill(imageRect)
        context.setBlendMode(.clear)
        for rect in rects {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func draw(_ annotation: EditorAnnotation, counterNumber: Int?, unitScale: CGFloat, in context: CGContext) {
        let color = annotation.style.color.cgColorValue
        let width = annotation.style.lineWidth

        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let applyShadow = {
            context.setShadow(
                offset: CGSize(width: 0, height: -1 * unitScale),
                blur: 3 * unitScale,
                color: NSColor.black.withAlphaComponent(0.35).cgColor
            )
        }

        switch annotation.kind {
        case let .line(start, end):
            applyShadow()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()

        case let .arrow(start, end):
            applyShadow()
            let head = ArrowHead(from: start, to: end, lineWidth: width)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.move(to: start)
            context.addLine(to: head.base)
            context.strokePath()
            context.move(to: head.tip)
            context.addLine(to: head.left)
            context.addLine(to: head.right)
            context.closePath()
            context.setLineWidth(max(width * 0.6, 1))
            context.drawPath(using: .fillStroke)
            context.endTransparencyLayer()

        case let .rectangle(rect):
            applyShadow()
            let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            context.addPath(path)
            context.drawPath(using: annotation.style.fill ? .fillStroke : .stroke)

        case let .ellipse(rect):
            applyShadow()
            context.addEllipse(in: rect)
            context.drawPath(using: annotation.style.fill ? .fillStroke : .stroke)

        case let .text(content, origin):
            drawText(content, origin: origin, style: annotation.style, unitScale: unitScale, in: context)

        case let .counter(center):
            applyShadow()
            let radius = AnnotationMetrics.counterRadius(lineWidth: width)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

            let label = "\(counterNumber ?? 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold),
                .foregroundColor: annotation.style.color.contrastingTextColor,
            ]
            let size = label.size(withAttributes: attributes)
            withFlippedGraphicsContext(context) {
                label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
            }

        case let .freehand(points):
            applyShadow()
            context.addPath(Self.smoothPath(points))
            context.strokePath()

        case let .highlight(points):
            context.setBlendMode(.multiply)
            context.setStrokeColor(NSColor(annotation.style.color).withAlphaComponent(0.45).cgColor)
            context.setLineWidth(AnnotationMetrics.highlightWidth(lineWidth: width))
            context.setLineCap(.square)
            context.addPath(Self.smoothPath(points))
            context.strokePath()

        case .obfuscate, .spotlight:
            break
        }
    }

    private func drawText(_ content: String, origin: CGPoint, style: AnnotationStyle, unitScale: CGFloat, in context: CGContext) {
        let rect = AnnotationMetrics.textRect(content: content, origin: origin, style: style)
        var textOrigin = origin
        let textColor: NSColor

        if style.textBackground {
            context.setShadow(
                offset: CGSize(width: 0, height: -1 * unitScale),
                blur: 4 * unitScale,
                color: NSColor.black.withAlphaComponent(0.3).cgColor
            )
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            textOrigin = CGPoint(x: origin.x + AnnotationMetrics.textPadding.width, y: origin.y + AnnotationMetrics.textPadding.height)
            textColor = style.color.contrastingTextColor
        } else {
            context.setShadow(
                offset: CGSize(width: 0, height: -1 * unitScale),
                blur: 3 * unitScale,
                color: NSColor.black.withAlphaComponent(0.45).cgColor
            )
            textColor = NSColor(style.color)
        }

        let attributed = NSAttributedString(string: content, attributes: [
            .font: AnnotationMetrics.textFont(size: style.fontSize),
            .foregroundColor: textColor,
        ])
        let size = AnnotationMetrics.textSize(content, fontSize: style.fontSize)

        withFlippedGraphicsContext(context) {
            attributed.draw(with: CGRect(origin: textOrigin, size: size), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private func withFlippedGraphicsContext(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Dibuja una imagen derecha en un contexto con el eje Y hacia abajo.
    private func drawUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        for index in 1 ..< points.count - 1 {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        if let last = points.last {
            path.addLine(to: last)
        }
        return path
    }
}

extension Color {
    var cgColorValue: CGColor {
        (NSColor(self).usingColorSpace(.sRGB) ?? .black).cgColor
    }

    /// Blanco o negro, el que mejor se lea sobre este color.
    var contrastingTextColor: NSColor {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.65 ? .black : .white
    }
}

extension CGColorSpace {
    /// Espacio de color valido para un contexto RGBA; si la imagen no es RGB se usa sRGB.
    static func renderable(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}
