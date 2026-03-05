import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class CaptureEditorWindowController: NSWindowController {
    private let closeDelegate: WindowDelegate
    private let viewModel: CaptureEditorViewModel

    init(image: NSImage, onCopy: @escaping (NSImage) -> Void, onClose: @escaping () -> Void) {
        self.closeDelegate = WindowDelegate(onClose: onClose)
        self.viewModel = CaptureEditorViewModel(baseImage: image)

        let contentView = CaptureEditorView(viewModel: viewModel, onCopy: onCopy)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Editor"
        window.minSize = NSSize(width: 700, height: 460)
        window.setContentSize(Self.preferredSize(for: image))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.window?.delegate = closeDelegate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private static func preferredSize(for image: NSImage) -> NSSize {
        let width = min(max(image.size.width + 180, 900), 1500)
        let height = min(max(image.size.height + 180, 620), 980)
        return NSSize(width: width, height: height)
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct CaptureEditorView: View {
    @ObservedObject var viewModel: CaptureEditorViewModel
    let onCopy: (NSImage) -> Void

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            CaptureEditorCanvasView(viewModel: viewModel)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(14)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    viewModel.activeTool = tool
                } label: {
                    Image(systemName: tool.iconName)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.activeTool == tool ? .accentColor : .gray.opacity(0.45))
            }

            Divider().frame(height: 22)

            ColorPicker("", selection: $viewModel.strokeColor)
                .labelsHidden()
                .frame(width: 30)

            Slider(value: $viewModel.lineWidth, in: 1...14)
                .frame(width: 110)

            Toggle("Relleno", isOn: $viewModel.fillShapes)
                .toggleStyle(.checkbox)

            if viewModel.activeTool == .text {
                TextField("Texto", text: $viewModel.textDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }

            Spacer()

            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)

            Button("Limpiar") {
                viewModel.clear()
            }

            Button("Guardar PNG") {
                saveImage(viewModel.renderedImage())
            }

            Button {
                onCopy(viewModel.renderedImage())
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command])
        }
    }

    private func saveImage(_ image: NSImage) {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "captura-editada.png"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pngData.write(to: url)
    }
}

private struct CaptureEditorCanvasView: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var freehandPoints: [CGPoint] = []

    var body: some View {
        GeometryReader { proxy in
            let imageSize = viewModel.baseImage.size
            let imageFrame = fittedRect(container: proxy.size, content: imageSize)

            ZStack(alignment: .topLeading) {
                Color.clear

                Image(nsImage: viewModel.baseImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                Canvas { context, _ in
                    drawAnnotations(context: context, imageFrame: imageFrame, imageSize: imageSize)
                }
            }
            .contentShape(Rectangle())
            .gesture(editorGesture(imageFrame: imageFrame, imageSize: imageSize))
        }
    }

    private func drawAnnotations(context: GraphicsContext, imageFrame: CGRect, imageSize: CGSize) {
        for annotation in viewModel.annotations {
            draw(annotation: annotation, context: context, imageFrame: imageFrame, imageSize: imageSize)
        }

        if let preview = previewAnnotation() {
            draw(annotation: preview, context: context, imageFrame: imageFrame, imageSize: imageSize)
        }
    }

    private func draw(annotation: EditorAnnotation, context: GraphicsContext, imageFrame: CGRect, imageSize: CGSize) {
        let strokeStyle = StrokeStyle(lineWidth: annotation.style.lineWidth, lineCap: .round, lineJoin: .round)
        let color = annotation.style.color

        switch annotation.kind {
        case .line(let start, let end):
            var path = Path()
            path.move(to: mapToView(start, imageFrame: imageFrame, imageSize: imageSize))
            path.addLine(to: mapToView(end, imageFrame: imageFrame, imageSize: imageSize))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .arrow(let start, let end):
            drawArrow(start: start, end: end, color: color, width: annotation.style.lineWidth, context: context, imageFrame: imageFrame, imageSize: imageSize)

        case .rectangle(let rect):
            let r = mapRectToView(rect, imageFrame: imageFrame, imageSize: imageSize)
            let path = Path(roundedRect: r, cornerRadius: 2)
            if annotation.style.fill {
                context.fill(path, with: .color(color.opacity(0.2)))
            }
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .ellipse(let rect):
            let r = mapRectToView(rect, imageFrame: imageFrame, imageSize: imageSize)
            let path = Path(ellipseIn: r)
            if annotation.style.fill {
                context.fill(path, with: .color(color.opacity(0.2)))
            }
            context.stroke(path, with: .color(color), style: strokeStyle)

        case .text(let content, let origin):
            let viewPoint = mapToView(origin, imageFrame: imageFrame, imageSize: imageSize)
            let resolved = context.resolve(Text(content).font(.system(size: max(annotation.style.lineWidth * 4, 14), weight: .semibold)).foregroundStyle(color))
            context.draw(resolved, at: viewPoint, anchor: .topLeading)

        case .freehand(let points):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: mapToView(first, imageFrame: imageFrame, imageSize: imageSize))
            for point in points.dropFirst() {
                path.addLine(to: mapToView(point, imageFrame: imageFrame, imageSize: imageSize))
            }
            context.stroke(path, with: .color(color), style: strokeStyle)
        }
    }

    private func editorGesture(imageFrame: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageFrame.contains(value.location) else { return }

                let imagePoint = mapToImage(value.location, imageFrame: imageFrame, imageSize: imageSize)

                if dragStart == nil {
                    dragStart = imagePoint
                    if viewModel.activeTool == .pencil {
                        freehandPoints = [imagePoint]
                    }
                }

                dragCurrent = imagePoint

                if viewModel.activeTool == .pencil {
                    freehandPoints.append(imagePoint)
                }
            }
            .onEnded { _ in
                guard let start = dragStart else { return resetDrag() }
                let end = dragCurrent ?? start

                switch viewModel.activeTool {
                case .line:
                    if start != end { viewModel.add(.line(start: start, end: end)) }
                case .arrow:
                    if start != end { viewModel.add(.arrow(start: start, end: end)) }
                case .rectangle:
                    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                    if rect.width > 1 && rect.height > 1 { viewModel.add(.rectangle(rect)) }
                case .ellipse:
                    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                    if rect.width > 1 && rect.height > 1 { viewModel.add(.ellipse(rect)) }
                case .text:
                    viewModel.add(.text(content: viewModel.textDraft.isEmpty ? "Texto" : viewModel.textDraft, origin: end))
                case .pencil:
                    if freehandPoints.count > 1 { viewModel.add(.freehand(points: freehandPoints)) }
                }

                resetDrag()
            }
    }

    private func resetDrag() {
        dragStart = nil
        dragCurrent = nil
        freehandPoints = []
    }

    private func previewAnnotation() -> EditorAnnotation? {
        guard let start = dragStart, let end = dragCurrent else { return nil }

        switch viewModel.activeTool {
        case .line:
            return EditorAnnotation(kind: .line(start: start, end: end), style: currentStyle)
        case .arrow:
            return EditorAnnotation(kind: .arrow(start: start, end: end), style: currentStyle)
        case .rectangle:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return EditorAnnotation(kind: .rectangle(rect), style: currentStyle)
        case .ellipse:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return EditorAnnotation(kind: .ellipse(rect), style: currentStyle)
        case .text:
            return EditorAnnotation(kind: .text(content: viewModel.textDraft.isEmpty ? "Texto" : viewModel.textDraft, origin: end), style: currentStyle)
        case .pencil:
            if freehandPoints.count > 1 {
                return EditorAnnotation(kind: .freehand(points: freehandPoints), style: currentStyle)
            }
            return nil
        }
    }

    private var currentStyle: AnnotationStyle {
        AnnotationStyle(color: viewModel.strokeColor, lineWidth: viewModel.lineWidth, fill: viewModel.fillShapes)
    }

    private func fittedRect(container: CGSize, content: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, content.width > 0, content.height > 0 else {
            return .zero
        }

        let scale = min(container.width / content.width, container.height / content.height)
        let width = content.width * scale
        let height = content.height * scale

        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func mapToImage(_ point: CGPoint, imageFrame: CGRect, imageSize: CGSize) -> CGPoint {
        let xRatio = (point.x - imageFrame.minX) / max(imageFrame.width, 1)
        let yRatio = (point.y - imageFrame.minY) / max(imageFrame.height, 1)
        return CGPoint(x: xRatio * imageSize.width, y: yRatio * imageSize.height)
    }

    private func mapToView(_ point: CGPoint, imageFrame: CGRect, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + (point.x / max(imageSize.width, 1)) * imageFrame.width,
            y: imageFrame.minY + (point.y / max(imageSize.height, 1)) * imageFrame.height
        )
    }

    private func mapRectToView(_ rect: CGRect, imageFrame: CGRect, imageSize: CGSize) -> CGRect {
        let origin = mapToView(rect.origin, imageFrame: imageFrame, imageSize: imageSize)
        let size = CGSize(
            width: (rect.width / max(imageSize.width, 1)) * imageFrame.width,
            height: (rect.height / max(imageSize.height, 1)) * imageFrame.height
        )
        return CGRect(origin: origin, size: size)
    }

    private func drawArrow(start: CGPoint, end: CGPoint, color: Color, width: CGFloat, context: GraphicsContext, imageFrame: CGRect, imageSize: CGSize) {
        let s = mapToView(start, imageFrame: imageFrame, imageSize: imageSize)
        let e = mapToView(end, imageFrame: imageFrame, imageSize: imageSize)

        var body = Path()
        body.move(to: s)
        body.addLine(to: e)
        context.stroke(body, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))

        let angle = atan2(e.y - s.y, e.x - s.x)
        let headLength = max(width * 4.5, 12)
        let spread = CGFloat.pi / 7

        let p1 = CGPoint(x: e.x - headLength * cos(angle - spread), y: e.y - headLength * sin(angle - spread))
        let p2 = CGPoint(x: e.x - headLength * cos(angle + spread), y: e.y - headLength * sin(angle + spread))

        var head = Path()
        head.move(to: e)
        head.addLine(to: p1)
        head.move(to: e)
        head.addLine(to: p2)
        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
