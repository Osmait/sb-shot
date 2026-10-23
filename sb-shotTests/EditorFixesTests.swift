import AppKit
@testable import SbShot
import Testing

// MARK: - Undo coalescing

@MainActor
struct EditorUndoCoalescingTests {
    private func makeViewModel() -> CaptureEditorViewModel {
        CaptureEditorViewModel(baseImage: NSImage(size: NSSize(width: 400, height: 300)))
    }

    /// Dibuja un rectangulo (queda seleccionado) y devuelve su viewmodel.
    private func makeViewModelWithRectangle() -> CaptureEditorViewModel {
        let viewModel = makeViewModel()
        viewModel.activeTool = .rectangle
        viewModel.pointerDown(at: CGPoint(x: 10, y: 10), tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: CGPoint(x: 110, y: 60), constrain: false)
        viewModel.pointerUp()
        return viewModel
    }

    /// Deshace hasta agotar la pila y devuelve cuantos pasos habia.
    private func undoAll(_ viewModel: CaptureEditorViewModel) -> Int {
        var steps = 0
        while viewModel.canUndo, steps < 200 {
            viewModel.undo()
            steps += 1
        }
        return steps
    }

    @Test func consecutiveSliderChangesWithSameKeyAreOneUndoStep() {
        let viewModel = makeViewModelWithRectangle()
        let original = viewModel.document.annotations[0].style.lineWidth

        viewModel.lineWidth = 6
        viewModel.lineWidth = 8
        viewModel.lineWidth = 10
        #expect(viewModel.document.annotations[0].style.lineWidth == 10)

        viewModel.undo()
        #expect(viewModel.document.annotations[0].style.lineWidth == original)
        #expect(viewModel.document.annotations.count == 1)

        // Queda solo la creacion del rectangulo.
        #expect(undoAll(viewModel) == 1)
    }

    @Test func differentKeyStartsNewGroup() {
        let viewModel = makeViewModelWithRectangle()
        let originalWidth = viewModel.document.annotations[0].style.lineWidth
        let originalColor = viewModel.document.annotations[0].style.color

        viewModel.lineWidth = 6
        viewModel.lineWidth = 8
        viewModel.strokeColor = CaptureEditorViewModel.palette[4]
        viewModel.strokeColor = CaptureEditorViewModel.palette[5]

        viewModel.undo()
        #expect(viewModel.document.annotations[0].style.color == originalColor)
        #expect(viewModel.document.annotations[0].style.lineWidth == 8)

        viewModel.undo()
        #expect(viewModel.document.annotations[0].style.lineWidth == originalWidth)
    }

    @Test func nonCoalescedMutationBreaksGroup() {
        let viewModel = makeViewModelWithRectangle()

        viewModel.lineWidth = 6
        viewModel.lineWidth = 7
        viewModel.fillShapes = true // paso propio
        viewModel.lineWidth = 9
        viewModel.lineWidth = 10

        // rectangulo + grupo(6,7) + relleno + grupo(9,10)
        #expect(undoAll(viewModel) == 4)
    }

    @Test func undoAndRedoBreakGroup() {
        let viewModel = makeViewModelWithRectangle()
        let original = viewModel.document.annotations[0].style.lineWidth

        viewModel.lineWidth = 6
        viewModel.undo()
        #expect(viewModel.document.annotations[0].style.lineWidth == original)

        // Tras deshacer, un nuevo cambio abre un grupo nuevo (y descarta el rehacer).
        viewModel.lineWidth = 7
        #expect(viewModel.canRedo == false)
        viewModel.lineWidth = 9
        #expect(undoAll(viewModel) == 2) // rectangulo + grupo(7,9)

        viewModel.redo()
        viewModel.redo()
        #expect(viewModel.document.annotations.count == 1)
        #expect(viewModel.document.annotations[0].style.lineWidth == 9)
    }

    @Test func backgroundChangesWithSameKeyAreOneUndoStep() {
        let viewModel = makeViewModel()
        let original = viewModel.document.background.padding

        viewModel.updateBackground(coalesceKey: "padding") { $0.padding = 10 }
        viewModel.updateBackground(coalesceKey: "padding") { $0.padding = 20 }
        viewModel.updateBackground(coalesceKey: "padding") { $0.padding = 30 }
        #expect(viewModel.document.background.padding == 30)

        viewModel.undo()
        #expect(viewModel.document.background.padding == original)
        #expect(viewModel.canUndo == false)
    }

    @Test func backgroundDifferentKeysAreSeparateSteps() {
        let viewModel = makeViewModel()
        let originalRadius = viewModel.document.background.cornerRadius

        viewModel.updateBackground(coalesceKey: "padding") { $0.padding = 10 }
        viewModel.updateBackground(coalesceKey: "radius") { $0.cornerRadius = 30 }

        viewModel.undo()
        #expect(viewModel.document.background.cornerRadius == originalRadius)
        #expect(viewModel.document.background.padding == 10)
        #expect(undoAll(viewModel) == 1)
    }

    @Test func backgroundWithoutKeyAlwaysCreatesNewStep() {
        let viewModel = makeViewModel()
        viewModel.updateBackground { $0.padding = 10 }
        viewModel.updateBackground { $0.padding = 20 }
        #expect(undoAll(viewModel) == 2)
    }

    @Test func unchangedBackgroundDoesNotCreateUndoStep() {
        let viewModel = makeViewModel()
        viewModel.updateBackground(coalesceKey: "padding") { $0.padding = $0.padding }
        #expect(viewModel.canUndo == false)
    }
}

// MARK: - Empty text discard

@MainActor
struct EditorEmptyTextTests {
    private func makeViewModel() -> CaptureEditorViewModel {
        CaptureEditorViewModel(baseImage: NSImage(size: NSSize(width: 400, height: 300)))
    }

    private func draw(_ viewModel: CaptureEditorViewModel, from: CGPoint, to: CGPoint) {
        viewModel.activeTool = .rectangle
        viewModel.pointerDown(at: from, tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: to, constrain: false)
        viewModel.pointerUp()
    }

    private func undoCount(_ viewModel: CaptureEditorViewModel) -> Int {
        var steps = 0
        while viewModel.canUndo, steps < 200 {
            viewModel.undo()
            steps += 1
        }
        return steps
    }

    @Test func emptyTextCommittedLeavesUndoAndRedoUntouched() {
        let viewModel = makeViewModel()
        draw(viewModel, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        draw(viewModel, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 160))
        viewModel.undo() // 1 en undo, 1 en redo
        let documentBefore = viewModel.document

        viewModel.activeTool = .text
        viewModel.pointerDown(at: CGPoint(x: 250, y: 200), tolerance: 4, clickCount: 1)
        #expect(viewModel.editingTextID != nil)
        #expect(viewModel.document.annotations.count == 2)

        viewModel.commitTextEditing()

        #expect(viewModel.editingTextID == nil)
        #expect(viewModel.document == documentBefore)
        #expect(viewModel.canRedo)
        #expect(undoCount(viewModel) == 1)
        viewModel.redo()
        viewModel.redo()
        #expect(viewModel.document.annotations.count == 2)
    }

    @Test func emptyTextDismissedBySwitchingToolPreservesRedo() {
        let viewModel = makeViewModel()
        draw(viewModel, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))
        viewModel.undo()
        #expect(viewModel.canRedo)

        viewModel.activeTool = .text
        viewModel.pointerDown(at: CGPoint(x: 250, y: 200), tolerance: 4, clickCount: 1)
        viewModel.deselect()

        #expect(viewModel.document.annotations.isEmpty)
        #expect(viewModel.canUndo == false)
        #expect(viewModel.canRedo)
    }

    @Test func undoWhileEditingEmptyTextOnlyDiscardsIt() {
        let viewModel = makeViewModel()
        draw(viewModel, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60))

        viewModel.activeTool = .text
        viewModel.pointerDown(at: CGPoint(x: 250, y: 200), tolerance: 4, clickCount: 1)
        viewModel.undo()

        // El rectangulo sigue ahi: el deshacer solo descarto el texto vacio.
        #expect(viewModel.document.annotations.count == 1)
        #expect(viewModel.canUndo)
    }

    @Test func nonEmptyTextIsKeptAsOneUndoStep() {
        let viewModel = makeViewModel()
        viewModel.activeTool = .text
        viewModel.pointerDown(at: CGPoint(x: 50, y: 50), tolerance: 4, clickCount: 1)
        viewModel.textDraft = "Hola"
        viewModel.commitTextEditing()

        #expect(viewModel.document.annotations.count == 1)
        #expect(undoCount(viewModel) == 1)
        #expect(viewModel.document.annotations.isEmpty)
    }
}
