import AppKit
import Combine
import SwiftUI

@MainActor
final class CaptureEditorViewModel: ObservableObject {
    static let palette: [Color] = [
        Color(red: 1.0, green: 0.23, blue: 0.19),
        Color(red: 1.0, green: 0.58, blue: 0.0),
        Color(red: 1.0, green: 0.8, blue: 0.0),
        Color(red: 0.2, green: 0.78, blue: 0.35),
        Color(red: 0.0, green: 0.48, blue: 1.0),
        Color(red: 0.69, green: 0.32, blue: 0.87),
        .black,
        .white,
    ]

    @Published var activeTool: EditorTool = .arrow {
        didSet { toolDidChange(from: oldValue) }
    }

    @Published var strokeColor: Color = palette[0] {
        didSet { applyStyleToSelection { $0.color = self.strokeColor } }
    }

    @Published var lineWidth: CGFloat = 4 {
        didSet { applyStyleToSelection { $0.lineWidth = self.lineWidth } }
    }

    @Published var fillShapes = false {
        didSet { applyStyleToSelection { $0.fill = self.fillShapes } }
    }

    @Published var fontSize: CGFloat = 28 {
        didSet { applyStyleToSelection { $0.fontSize = self.fontSize } }
    }

    @Published var textBackground = false {
        didSet { applyStyleToSelection { $0.textBackground = self.textBackground } }
    }

    @Published var obfuscation: ObfuscationMode = .pixelate {
        didSet { applyStyleToSelection { $0.obfuscation = self.obfuscation } }
    }

    @Published private(set) var document = EditorDocument()
    @Published private(set) var draft: EditorAnnotation?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var editingTextID: UUID?
    @Published var textDraft = "" {
        didSet { updateEditingText() }
    }

    @Published var cropDraft: CGRect?

    let baseImage: NSImage
    let previewSources: RenderSources?
    let renderer = AnnotationRenderer()

    private lazy var exportSources: RenderSources? = RenderSources(image: baseImage)
    private var undoStack: [EditorDocument] = []
    private var redoStack: [EditorDocument] = []
    private var interaction: Interaction?
    private var isSyncingStyle = false
    private var lastCoalescedChange: (key: String, date: Date)?
    private var toolBeforeCrop: EditorTool = .arrow
    private var skipCropCommit = false

    private enum Interaction {
        case drawing(start: CGPoint, points: [CGPoint])
        case moving(id: UUID, origin: CGPoint, snapshot: EditorDocument, moved: Bool)
        case resizing(id: UUID, handle: AnnotationHandle, snapshot: EditorDocument)
        case cropping(start: CGPoint)
        case cropResizing(handle: AnnotationHandle, original: CGRect)
        case cropMoving(origin: CGPoint, original: CGRect)
    }

    init(baseImage: NSImage) {
        self.baseImage = baseImage
        previewSources = RenderSources(image: baseImage, maxPixelDimension: 2800)
    }

    // MARK: - Derived state

    var imageRect: CGRect {
        CGRect(origin: .zero, size: baseImage.size)
    }

    var isCropping: Bool {
        activeTool == .crop
    }

    var layout: RenderLayout {
        RenderLayout(document: document, imageSize: baseImage.size, applyCropAndBackground: !isCropping)
    }

    /// Documento con la forma que se esta dibujando, para el lienzo.
    var displayDocument: EditorDocument {
        var display = document
        if let draft {
            display.annotations.append(draft)
        }
        return display
    }

    var selectedAnnotation: EditorAnnotation? {
        guard let selectedID else { return nil }
        return document.annotations.first { $0.id == selectedID }
    }

    var editingAnnotation: EditorAnnotation? {
        guard let editingTextID else { return nil }
        return document.annotations.first { $0.id == editingTextID }
    }

    /// Herramienta cuyos controles de estilo se muestran: la de la anotacion seleccionada o la activa.
    var styleTool: EditorTool {
        guard let selectedAnnotation else { return activeTool }
        return Self.tool(for: selectedAnnotation.kind)
    }

    var outputPixelSize: CGSize {
        let scale = exportSources?.pixelScale ?? 1
        let size = RenderLayout(document: document, imageSize: baseImage.size).outputSize
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    var hasChanges: Bool {
        document != EditorDocument()
    }

    // MARK: - Pointer

    func pointerDown(at point: CGPoint, tolerance: CGFloat, clickCount: Int) {
        if editingTextID != nil {
            commitTextEditing()
        }

        if isCropping {
            beginCropInteraction(at: point, tolerance: tolerance)
            return
        }

        if let selected = selectedAnnotation,
           let handle = selected.handles.first(where: { hypot($0.value.x - point.x, $0.value.y - point.y) <= tolerance * 1.5 })?.key
        {
            interaction = .resizing(id: selected.id, handle: handle, snapshot: document)
            return
        }

        let hit = topmostAnnotation(at: point, tolerance: tolerance)
        let canGrab = activeTool == .select || (hit != nil && hit?.id == selectedID)

        if canGrab, let hit {
            select(hit)
            if clickCount >= 2, hit.isText {
                beginEditingText(hit)
                return
            }
            interaction = .moving(id: hit.id, origin: point, snapshot: document, moved: false)
            return
        }

        if activeTool == .select {
            selectedID = nil
            return
        }

        selectedID = nil

        switch activeTool {
        case .text:
            if let hit, hit.isText {
                select(hit)
                beginEditingText(hit)
            } else {
                createText(at: point)
            }
        case .counter:
            commit(EditorAnnotation(kind: .counter(center: point), style: currentStyle), selectAfter: false)
        default:
            interaction = .drawing(start: point, points: [point])
            draft = nil
        }
    }

    func pointerDragged(to point: CGPoint, constrain: Bool) {
        guard let interaction else { return }

        switch interaction {
        case let .drawing(start, points):
            var updatedPoints = points
            if activeTool == .pencil || activeTool == .highlighter {
                updatedPoints.append(point)
            }
            self.interaction = .drawing(start: start, points: updatedPoints)
            let end = constrain ? constrained(start: start, end: point) : point
            draft = annotation(start: start, end: end, points: updatedPoints)

        case let .moving(id, origin, snapshot, _):
            guard let original = snapshot.annotations.first(where: { $0.id == id }) else { return }
            let moved = original.translated(by: CGSize(width: point.x - origin.x, height: point.y - origin.y))
            replace(moved)
            self.interaction = .moving(id: id, origin: origin, snapshot: snapshot, moved: true)

        case let .resizing(id, handle, snapshot):
            guard let original = snapshot.annotations.first(where: { $0.id == id }) else { return }
            replace(original.resized(handle: handle, to: point))

        case let .cropping(start):
            cropDraft = CGRect.spanning(start, point).intersection(imageRect)

        case let .cropResizing(handle, original):
            cropDraft = original.resized(handle: handle, to: point).intersection(imageRect)

        case let .cropMoving(origin, original):
            var moved = original.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y)
            moved.origin.x = min(max(moved.minX, 0), imageRect.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), imageRect.height - moved.height)
            cropDraft = moved
        }
    }

    func pointerUp() {
        defer { interaction = nil }
        guard let interaction else { return }

        switch interaction {
        case .drawing:
            if let draft, Self.isValid(draft) {
                let selectable = ![.pencil, .highlighter].contains(activeTool)
                commit(draft, selectAfter: selectable)
            }
            draft = nil

        case let .moving(_, _, snapshot, moved):
            if moved {
                pushUndo(snapshot)
            }

        case let .resizing(_, _, snapshot):
            if snapshot != document {
                pushUndo(snapshot)
            }

        case .cropping, .cropResizing, .cropMoving:
            if let cropDraft, cropDraft.width < 4 || cropDraft.height < 4 {
                self.cropDraft = nil
            }
        }
    }

    // MARK: - Editing commands

    func deleteSelection() {
        guard let selectedID else { return }
        mutate { $0.annotations.removeAll { $0.id == selectedID } }
        self.selectedID = nil
    }

    func deselect() {
        if editingTextID != nil {
            commitTextEditing()
        }
        selectedID = nil
    }

    func clear() {
        guard !document.annotations.isEmpty else { return }
        commitTextEditing()
        mutate { $0.annotations.removeAll() }
        selectedID = nil
    }

    func undo() {
        commitTextEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        validateSelection()
    }

    func redo() {
        commitTextEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        validateSelection()
    }

    func renderedImage() -> NSImage {
        commitTextEditing()
        guard let sources = exportSources ?? previewSources else { return baseImage }
        return renderer.render(document: document, sources: sources)
    }

    // MARK: - Text

    func commitTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil

        let content = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            document.annotations.removeAll { $0.id == id }
            if selectedID == id {
                selectedID = nil
            }
        }
    }

    private func createText(at point: CGPoint) {
        let annotation = EditorAnnotation(kind: .text(content: "", origin: point), style: currentStyle)
        commit(annotation, selectAfter: true)
        beginEditingText(annotation)
    }

    private func beginEditingText(_ annotation: EditorAnnotation) {
        guard case let .text(content, _) = annotation.kind else { return }
        if !content.isEmpty {
            pushUndo(document)
        }
        editingTextID = annotation.id
        textDraft = content
    }

    private func updateEditingText() {
        guard
            let id = editingTextID,
            let index = document.annotations.firstIndex(where: { $0.id == id }),
            case let .text(_, origin) = document.annotations[index].kind
        else { return }
        document.annotations[index].kind = .text(content: textDraft, origin: origin)
    }

    // MARK: - Crop

    func confirmCrop() {
        activeTool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    func cancelCrop() {
        skipCropCommit = true
        cropDraft = document.cropRect
        activeTool = toolBeforeCrop == .crop ? .select : toolBeforeCrop
    }

    func resetCrop() {
        cropDraft = nil
        if document.cropRect != nil {
            mutate { $0.cropRect = nil }
        }
    }

    private func beginCropInteraction(at point: CGPoint, tolerance: CGFloat) {
        let rect = cropDraft ?? imageRect

        if let handle = CGRect.cornerHandles.first(where: {
            let corner = rect.point(for: $0)
            return hypot(corner.x - point.x, corner.y - point.y) <= tolerance * 2
        }) {
            interaction = .cropResizing(handle: handle, original: rect)
        } else if cropDraft != nil, rect.contains(point) {
            interaction = .cropMoving(origin: point, original: rect)
        } else {
            cropDraft = nil
            interaction = .cropping(start: point)
        }
    }

    // MARK: - Background

    func updateBackground(coalesceKey: String? = nil, _ change: (inout BackgroundSettings) -> Void) {
        var background = document.background
        change(&background)
        guard background != document.background else { return }

        if let coalesceKey, shouldCoalesce(key: coalesceKey) {
            document.background = background
        } else {
            mutate { $0.background = background }
        }
    }

    // MARK: - Private helpers

    private var currentStyle: AnnotationStyle {
        AnnotationStyle(
            color: strokeColor,
            lineWidth: lineWidth,
            fill: fillShapes,
            fontSize: fontSize,
            textBackground: textBackground,
            obfuscation: obfuscation
        )
    }

    private func toolDidChange(from oldValue: EditorTool) {
        guard oldValue != activeTool else { return }
        commitTextEditing()
        interaction = nil
        draft = nil

        if activeTool == .crop {
            toolBeforeCrop = oldValue
            selectedID = nil
            cropDraft = document.cropRect
        }

        if oldValue == .crop {
            if !skipCropCommit {
                let newCrop = cropDraft.flatMap { $0.width >= 4 && $0.height >= 4 ? $0.integral : nil }
                if newCrop != document.cropRect {
                    mutate { $0.cropRect = newCrop }
                }
            }
            skipCropCommit = false
        }

        if activeTool != .select, let selectedAnnotation, Self.tool(for: selectedAnnotation.kind) != activeTool {
            selectedID = nil
        }
    }

    private func select(_ annotation: EditorAnnotation) {
        selectedID = annotation.id
        isSyncingStyle = true
        strokeColor = annotation.style.color
        lineWidth = annotation.style.lineWidth
        fillShapes = annotation.style.fill
        fontSize = annotation.style.fontSize
        textBackground = annotation.style.textBackground
        obfuscation = annotation.style.obfuscation
        isSyncingStyle = false
    }

    private func applyStyleToSelection(_ change: (inout AnnotationStyle) -> Void) {
        guard !isSyncingStyle, let selectedID, let index = document.annotations.firstIndex(where: { $0.id == selectedID }) else { return }

        var style = document.annotations[index].style
        change(&style)
        guard style != document.annotations[index].style else { return }

        if shouldCoalesce(key: "style-\(selectedID)") {
            document.annotations[index].style = style
        } else {
            mutate { $0.annotations[index].style = style }
        }
    }

    /// Agrupa cambios seguidos (por ejemplo, mover un slider) en un solo paso de deshacer.
    private func shouldCoalesce(key: String) -> Bool {
        defer { lastCoalescedChange = (key, Date()) }
        guard let last = lastCoalescedChange else { return false }
        return last.key == key && Date().timeIntervalSince(last.date) < 1.0
    }

    private func commit(_ annotation: EditorAnnotation, selectAfter: Bool) {
        mutate { $0.annotations.append(annotation) }
        selectedID = selectAfter ? annotation.id : nil
    }

    private func replace(_ annotation: EditorAnnotation) {
        guard let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        document.annotations[index] = annotation
    }

    private func mutate(_ change: (inout EditorDocument) -> Void) {
        pushUndo(document)
        change(&document)
    }

    private func pushUndo(_ snapshot: EditorDocument) {
        lastCoalescedChange = nil
        undoStack.append(snapshot)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
    }

    private func validateSelection() {
        if let selectedID, !document.annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if let editingTextID, !document.annotations.contains(where: { $0.id == editingTextID }) {
            self.editingTextID = nil
        }
    }

    private func topmostAnnotation(at point: CGPoint, tolerance: CGFloat) -> EditorAnnotation? {
        document.annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    private func annotation(start: CGPoint, end: CGPoint, points: [CGPoint]) -> EditorAnnotation? {
        let rect = CGRect.spanning(start, end)
        let kind: EditorAnnotation.Kind? = switch activeTool {
        case .line: .line(start: start, end: end)
        case .arrow: .arrow(start: start, end: end)
        case .rectangle: .rectangle(rect)
        case .ellipse: .ellipse(rect)
        case .obfuscate: .obfuscate(rect)
        case .spotlight: .spotlight(rect)
        case .pencil: .freehand(points: points)
        case .highlighter: .highlight(points: points)
        case .select, .text, .counter, .crop: nil
        }
        return kind.map { EditorAnnotation(kind: $0, style: currentStyle) }
    }

    private func constrained(start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y

        switch activeTool {
        case .line, .arrow:
            let angle = atan2(dy, dx)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(snapped) * length, y: start.y + sin(snapped) * length)
        case .rectangle, .ellipse, .obfuscate, .spotlight:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            return end
        }
    }

    private static func isValid(_ annotation: EditorAnnotation) -> Bool {
        switch annotation.kind {
        case let .line(start, end), let .arrow(start, end):
            hypot(end.x - start.x, end.y - start.y) > 3
        case let .rectangle(rect), let .ellipse(rect), let .obfuscate(rect), let .spotlight(rect):
            rect.width > 3 && rect.height > 3
        case let .freehand(points), let .highlight(points):
            points.count > 1
        case .text, .counter:
            true
        }
    }

    static func tool(for kind: EditorAnnotation.Kind) -> EditorTool {
        switch kind {
        case .line: .line
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .text: .text
        case .counter: .counter
        case .freehand: .pencil
        case .highlight: .highlighter
        case .obfuscate: .obfuscate
        case .spotlight: .spotlight
        }
    }
}
