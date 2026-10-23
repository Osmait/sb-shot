import AppKit
import SwiftUI

final class CaptureEditorWindowController: NSWindowController {
    private let closeDelegate: WindowDelegate
    private let viewModel: CaptureEditorViewModel

    init(image: NSImage, onCopy: @escaping (NSImage) -> Void, onClose: @escaping () -> Void) {
        closeDelegate = WindowDelegate(onClose: onClose)
        viewModel = CaptureEditorViewModel(baseImage: image)

        let contentView = CaptureEditorView(viewModel: viewModel, onCopy: onCopy)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 780, height: 520)
        window.setContentSize(Self.preferredSize(for: image))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.window?.delegate = closeDelegate
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
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

    func windowWillClose(_: Notification) {
        onClose()
    }
}

private struct CaptureEditorView: View {
    @ObservedObject var viewModel: CaptureEditorViewModel
    let onCopy: (NSImage) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.top, 38)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            CaptureEditorCanvasView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(EditorColors.canvasBackground)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolGroup
            styleGroup

            if viewModel.activeTool == .text {
                TextField("Texto", text: $viewModel.textDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 140)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()

            undoRedoGroup
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeTool)
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                ToolButton(icon: tool.iconName, isSelected: viewModel.activeTool == tool) {
                    viewModel.activeTool = tool
                }
            }
        }
        .toolbarGroup()
    }

    private var styleGroup: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: $viewModel.strokeColor)
                .labelsHidden()
                .frame(width: 24)

            Slider(value: $viewModel.lineWidth, in: 1 ... 14)
                .frame(width: 80)

            Button {
                viewModel.fillShapes.toggle()
            } label: {
                Image(systemName: viewModel.fillShapes ? "square.fill" : "square")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(viewModel.fillShapes ? .white : .secondary)
            }
            .buttonStyle(.plain)
        }
        .toolbarGroup()
    }

    private var undoRedoGroup: some View {
        HStack(spacing: 2) {
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canUndo ? .white : .white.opacity(0.25))
            .disabled(!viewModel.canUndo)

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.canRedo ? .white : .white.opacity(0.25))
            .disabled(!viewModel.canRedo)
        }
        .toolbarGroup()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.clear()
            } label: {
                Label("Limpiar", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))
            .disabled(viewModel.annotations.isEmpty)

            Spacer()

            if !viewModel.annotations.isEmpty {
                Text("\(viewModel.annotations.count) anotacion\(viewModel.annotations.count == 1 ? "" : "es")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Guardar") {
                saveImage(viewModel.renderedImage())
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))

            Button {
                onCopy(viewModel.renderedImage())
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            .buttonStyle(ActionButtonStyle())
            .keyboardShortcut("c", modifiers: [.command])
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EditorColors.groupBorder, lineWidth: 1))
    }

    private func saveImage(_ image: NSImage) {
        ImageExporter.savePNG(image, defaultName: "captura-editada.png")
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
                EditorColors.canvasBackground

                Image(nsImage: viewModel.baseImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 4)
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
        case let .line(start, end):
            var path = Path()
            path.move(to: mapToView(start, imageFrame: imageFrame, imageSize: imageSize))
            path.addLine(to: mapToView(end, imageFrame: imageFrame, imageSize: imageSize))
            context.stroke(path, with: .color(color), style: strokeStyle)

        case let .arrow(start, end):
            drawArrow(annotation: annotation, start: start, end: end, context: context, imageFrame: imageFrame, imageSize: imageSize)

        case let .rectangle(rect):
            let r = mapRectToView(rect, imageFrame: imageFrame, imageSize: imageSize)
            let path = Path(roundedRect: r, cornerRadius: 2)
            if annotation.style.fill {
                context.fill(path, with: .color(color.opacity(0.2)))
            }
            context.stroke(path, with: .color(color), style: strokeStyle)

        case let .ellipse(rect):
            let r = mapRectToView(rect, imageFrame: imageFrame, imageSize: imageSize)
            let path = Path(ellipseIn: r)
            if annotation.style.fill {
                context.fill(path, with: .color(color.opacity(0.2)))
            }
            context.stroke(path, with: .color(color), style: strokeStyle)

        case let .text(content, origin):
            let viewPoint = mapToView(origin, imageFrame: imageFrame, imageSize: imageSize)
            let resolved = context.resolve(Text(content).font(.system(size: max(annotation.style.lineWidth * 4, 14), weight: .semibold)).foregroundStyle(color))
            context.draw(resolved, at: viewPoint, anchor: .topLeading)

        case let .freehand(points):
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
                handleDragChanged(value: value, imageFrame: imageFrame, imageSize: imageSize)
            }
            .onEnded { _ in
                commitDrag()
            }
    }

    private func handleDragChanged(value: DragGesture.Value, imageFrame: CGRect, imageSize: CGSize) {
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

    private func commitDrag() {
        guard let start = dragStart else { return resetDrag() }
        let end = dragCurrent ?? start

        if let annotation = annotationForDrag(start: start, end: end) {
            viewModel.add(annotation)
        }
        resetDrag()
    }

    private func annotationForDrag(start: CGPoint, end: CGPoint) -> EditorAnnotation.Kind? {
        switch viewModel.activeTool {
        case .line:
            return start != end ? .line(start: start, end: end) : nil
        case .arrow:
            return start != end ? .arrow(start: start, end: end) : nil
        case .rectangle:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return rect.width > 1 && rect.height > 1 ? .rectangle(rect) : nil
        case .ellipse:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            return rect.width > 1 && rect.height > 1 ? .ellipse(rect) : nil
        case .text:
            return .text(content: viewModel.textDraft.isEmpty ? "Texto" : viewModel.textDraft, origin: end)
        case .pencil:
            return freehandPoints.count > 1 ? .freehand(points: freehandPoints) : nil
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

    // swiftlint:disable:next function_parameter_count
    private func drawArrow(
        annotation: EditorAnnotation,
        start: CGPoint,
        end: CGPoint,
        context: GraphicsContext,
        imageFrame: CGRect,
        imageSize: CGSize
    ) {
        let s = mapToView(start, imageFrame: imageFrame, imageSize: imageSize)
        let e = mapToView(end, imageFrame: imageFrame, imageSize: imageSize)
        let color = annotation.style.color
        let width = annotation.style.lineWidth
        let strokeStyle = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

        var shaft = Path()
        shaft.move(to: s)
        shaft.addLine(to: e)
        context.stroke(shaft, with: .color(color), style: strokeStyle)

        let arrowHead = ArrowHead(from: s, to: e, lineWidth: width)

        var head = Path()
        head.move(to: arrowHead.tip)
        head.addLine(to: arrowHead.left)
        head.move(to: arrowHead.tip)
        head.addLine(to: arrowHead.right)
        context.stroke(head, with: .color(color), style: strokeStyle)
    }
}
