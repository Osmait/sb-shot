import AppKit
import SwiftUI
import Combine

@MainActor
final class CaptureEditorViewModel: ObservableObject {
    @Published var activeTool: EditorTool = .arrow
    @Published var strokeColor: Color = .red
    @Published var lineWidth: CGFloat = 3
    @Published var fillShapes = false
    @Published var textDraft = "Texto"
    @Published private(set) var annotations: [EditorAnnotation] = []

    let baseImage: NSImage
    private let renderer = AnnotationRenderer()
    private var undoStack: [[EditorAnnotation]] = []
    private var redoStack: [[EditorAnnotation]] = []

    init(baseImage: NSImage) {
        self.baseImage = baseImage
    }

    func add(_ kind: EditorAnnotation.Kind) {
        pushUndoSnapshot()
        annotations.append(EditorAnnotation(kind: kind, style: currentStyle))
        redoStack.removeAll()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        pushUndoSnapshot()
        annotations.removeAll()
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func renderedImage() -> NSImage {
        renderer.render(baseImage: baseImage, annotations: annotations)
    }

    private var currentStyle: AnnotationStyle {
        AnnotationStyle(color: strokeColor, lineWidth: lineWidth, fill: fillShapes)
    }

    private func pushUndoSnapshot() {
        undoStack.append(annotations)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
    }
}
