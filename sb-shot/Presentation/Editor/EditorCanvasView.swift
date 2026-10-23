import AppKit
import SwiftUI

/// Lienzo del editor. Dibuja el documento con el mismo renderer que la exportacion y traduce el raton
/// a coordenadas de la imagen.
struct EditorCanvasView: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    @State private var isPointerDown = false
    @State private var lastDown: (date: Date, point: CGPoint)?
    @FocusState private var isTextFocused: Bool

    private let padding: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let layout = viewModel.layout
            let transform = CanvasTransform(container: proxy.size, content: layout.outputSize, padding: padding)

            ZStack(alignment: .topLeading) {
                EditorColors.canvasBackground

                Canvas { context, _ in
                    drawDocument(in: context, layout: layout, transform: transform)
                    drawSelection(in: context, layout: layout, transform: transform)
                    drawCropOverlay(in: context, layout: layout, transform: transform)
                }

                if let annotation = viewModel.editingAnnotation {
                    textEditor(for: annotation, layout: layout, transform: transform)
                }
            }
            .contentShape(Rectangle())
            .gesture(pointerGesture(layout: layout, transform: transform))
            .pointerStyle(pointerStyle)
        }
    }

    // MARK: - Drawing

    private func drawDocument(in context: GraphicsContext, layout: RenderLayout, transform: CanvasTransform) {
        guard let sources = viewModel.previewSources else { return }

        var shadowContext = context
        shadowContext.addFilter(.shadow(color: .black.opacity(layout.background == nil ? 0.45 : 0), radius: 18, y: 4))
        shadowContext.fill(Path(transform.toView(CGRect(origin: .zero, size: layout.outputSize))), with: .color(.black))

        context.withCGContext { cgContext in
            cgContext.translateBy(x: transform.origin.x, y: transform.origin.y)
            cgContext.scaleBy(x: transform.scale, y: transform.scale)
            viewModel.renderer.draw(
                document: viewModel.displayDocument,
                layout: layout,
                sources: sources,
                in: cgContext,
                excludingAnnotationID: viewModel.editingTextID
            )
        }
    }

    private func drawSelection(in context: GraphicsContext, layout: RenderLayout, transform: CanvasTransform) {
        guard let annotation = viewModel.selectedAnnotation, viewModel.editingTextID == nil, !viewModel.isCropping else { return }

        let accent = Color.accentColor
        let handles = annotation.handles

        if handles.isEmpty || annotation.isText {
            let bounds = transform.toView(layout.toOutput(annotation.bounds)).insetBy(dx: -4, dy: -4)
            context.stroke(Path(roundedRect: bounds, cornerRadius: 3), with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else if case .line = annotation.kind {
            // Las lineas solo muestran sus extremos.
        } else if case .arrow = annotation.kind {
            // Igual que las lineas.
        } else {
            let bounds = transform.toView(layout.toOutput(annotation.bounds))
            context.stroke(Path(bounds), with: .color(accent.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        for point in handles.values {
            let center = transform.toView(layout.toOutput(point))
            let handleRect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: handleRect), with: .color(.white))
            context.stroke(Path(ellipseIn: handleRect), with: .color(accent), lineWidth: 2)
        }
    }

    private func drawCropOverlay(in context: GraphicsContext, layout: RenderLayout, transform: CanvasTransform) {
        guard viewModel.isCropping else { return }

        let imageRect = transform.toView(layout.toOutput(viewModel.imageRect))
        let cropRect = transform.toView(layout.toOutput(viewModel.cropDraft ?? viewModel.imageRect))

        var dim = Path(imageRect)
        dim.addRect(cropRect)
        context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

        context.stroke(Path(cropRect), with: .color(.white), lineWidth: 1.5)

        var thirds = Path()
        for index in 1 ... 2 {
            let x = cropRect.minX + cropRect.width * CGFloat(index) / 3
            let y = cropRect.minY + cropRect.height * CGFloat(index) / 3
            thirds.move(to: CGPoint(x: x, y: cropRect.minY))
            thirds.addLine(to: CGPoint(x: x, y: cropRect.maxY))
            thirds.move(to: CGPoint(x: cropRect.minX, y: y))
            thirds.addLine(to: CGPoint(x: cropRect.maxX, y: y))
        }
        context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)

        for handle in CGRect.cornerHandles {
            let corner = cropRect.point(for: handle)
            let rect = CGRect(x: corner.x - 6, y: corner.y - 6, width: 12, height: 12)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white))
        }

        if let draft = viewModel.cropDraft {
            let label = Text("\(Int(draft.width)) × \(Int(draft.height))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            context.draw(label, at: CGPoint(x: cropRect.midX, y: cropRect.maxY + 14))
        }
    }

    // MARK: - Text editing

    @ViewBuilder
    private func textEditor(for annotation: EditorAnnotation, layout: RenderLayout, transform: CanvasTransform) -> some View {
        if case let .text(_, origin) = annotation.kind {
            let style = annotation.style
            let viewOrigin = transform.toView(layout.toOutput(origin))
            let padding = style.textBackground ? AnnotationMetrics.textPadding : .zero

            TextField("Escribe aquí", text: $viewModel.textDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: style.fontSize * transform.scale, weight: .bold))
                .foregroundStyle(style.textBackground ? Color(nsColor: style.color.contrastingTextColor) : style.color)
                .fixedSize()
                .frame(minWidth: 60 * transform.scale, alignment: .leading)
                .padding(.horizontal, padding.width * transform.scale)
                .padding(.vertical, padding.height * transform.scale)
                .background(
                    RoundedRectangle(cornerRadius: 6 * transform.scale)
                        .fill(style.textBackground ? style.color : Color.black.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6 * transform.scale)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .offset(x: viewOrigin.x, y: viewOrigin.y)
                .focused($isTextFocused)
                .onSubmit { viewModel.commitTextEditing() }
                .onAppear { isTextFocused = true }
        }
    }

    // MARK: - Gestures

    private func pointerGesture(layout: RenderLayout, transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = layout.toImage(transform.toContent(value.location))

                if !isPointerDown {
                    isPointerDown = true
                    let now = Date()
                    var clickCount = 1
                    if let lastDown, now.timeIntervalSince(lastDown.date) < NSEvent.doubleClickInterval,
                       hypot(lastDown.point.x - value.location.x, lastDown.point.y - value.location.y) < 5
                    {
                        clickCount = 2
                    }
                    lastDown = (now, value.location)
                    viewModel.pointerDown(at: point, tolerance: 6 / max(transform.scale, 0.01), clickCount: clickCount)
                } else {
                    viewModel.pointerDragged(to: point, constrain: NSEvent.modifierFlags.contains(.shift))
                }
            }
            .onEnded { _ in
                isPointerDown = false
                viewModel.pointerUp()
            }
    }

    private var pointerStyle: PointerStyle {
        switch viewModel.activeTool {
        case .select: .default
        case .text: .horizontalText
        default: .rectSelection
        }
    }
}

/// Escala y desplazamiento del lienzo de salida dentro de la vista.
struct CanvasTransform {
    let scale: CGFloat
    let origin: CGPoint

    init(container: CGSize, content: CGSize, padding: CGFloat) {
        let available = CGSize(width: max(container.width - padding * 2, 1), height: max(container.height - padding * 2, 1))
        let fit = min(available.width / max(content.width, 1), available.height / max(content.height, 1))
        scale = min(fit, 1)
        origin = CGPoint(
            x: (container.width - content.width * scale) / 2,
            y: (container.height - content.height * scale) / 2
        )
    }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func toContent(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }
}
