//
//  SbShotTests.swift
//  sb-shotTests
//
//  Created by Jose Saul Burgos on 3/4/26.
//

import AppKit
@testable import SbShot
import SwiftUI
import Testing

@MainActor
struct CaptureScreenshotUseCaseTests {
    private let area = CGRect(x: 10, y: 10, width: 50, height: 40)

    @Test func capturesSelectedArea() async {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let capturer = MockCapturer(result: .success(image))
        let useCase = makeUseCase(selector: MockSelector(selection: .area(area)), capturer: capturer)

        let outcome = await useCase.execute(mode: .area)

        guard case let .captured(capturedImage, selection) = outcome else {
            Issue.record("Expected capture outcome")
            return
        }

        #expect(capturedImage.size == image.size)
        #expect(selection == .area(area))
        #expect(capturer.captured == [.area(area)])
    }

    @Test func requestsPermissionAndOpensSettingsWhenDenied() async {
        let permissions = MockPermissions(preflight: false, requestResult: false)
        let capturer = MockCapturer(result: .failure(MockError.captureFailed))
        let useCase = makeUseCase(permissions: permissions, selector: MockSelector(selection: nil), capturer: capturer)

        let outcome = await useCase.execute(mode: .area)

        guard case .permissionDenied = outcome else {
            Issue.record("Expected permission denied outcome")
            return
        }

        #expect(permissions.requestCount == 1)
        #expect(permissions.openSettingsCount == 1)
        #expect(capturer.captured.isEmpty)
    }

    @Test func returnsCancelledWhenSelectionIsCancelled() async {
        let capturer = MockCapturer(result: .failure(MockError.captureFailed))
        let useCase = makeUseCase(selector: MockSelector(selection: nil), capturer: capturer)

        let outcome = await useCase.execute(mode: .area)

        guard case .cancelled = outcome else {
            Issue.record("Expected cancelled outcome")
            return
        }
        #expect(capturer.captured.isEmpty)
    }

    @Test func usesFrozenImageWithoutCapturingAgain() async {
        let frozen = NSImage(size: NSSize(width: 50, height: 40))
        let capturer = MockCapturer(result: .failure(MockError.captureFailed))
        let selector = MockSelector(selection: .area(area), frozenImage: frozen)
        let useCase = makeUseCase(selector: selector, capturer: capturer)

        let outcome = await useCase.execute(mode: .area)

        guard case let .captured(image, _) = outcome else {
            Issue.record("Expected capture outcome")
            return
        }
        #expect(image === frozen)
        #expect(capturer.captured.isEmpty)
    }

    @Test func previousAreaSkipsSelection() async {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let selector = MockSelector(selection: nil)
        let capturer = MockCapturer(result: .success(image))
        let useCase = makeUseCase(selector: selector, capturer: capturer)

        let outcome = await useCase.execute(mode: .previousArea, previousArea: area)

        guard case .captured = outcome else {
            Issue.record("Expected capture outcome")
            return
        }
        #expect(selector.selectCount == 0)
        #expect(capturer.captured == [.area(area)])
    }

    @Test func fullscreenCapturesDisplayUnderCursor() async {
        let display = ScreenSelection.display(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let selector = MockSelector(selection: nil, display: display)
        let capturer = MockCapturer(result: .success(NSImage(size: NSSize(width: 100, height: 100))))
        let useCase = makeUseCase(selector: selector, capturer: capturer)

        _ = await useCase.execute(mode: .fullscreen)

        #expect(selector.selectCount == 0)
        #expect(capturer.captured == [display])
    }

    @Test func timedCaptureCancelsWhenCountdownIsCancelled() async {
        let capturer = MockCapturer(result: .success(NSImage(size: NSSize(width: 10, height: 10))))
        let countdown = MockCountdown(completes: false)
        let useCase = makeUseCase(selector: MockSelector(selection: .area(area)), capturer: capturer, countdown: countdown)

        let outcome = await useCase.execute(mode: .timed(seconds: 3))

        guard case .cancelled = outcome else {
            Issue.record("Expected cancelled outcome")
            return
        }
        #expect(countdown.requestedSeconds == 3)
        #expect(capturer.captured.isEmpty)
    }

    private func makeUseCase(
        permissions: MockPermissions = MockPermissions(preflight: true, requestResult: true),
        selector: MockSelector,
        capturer: MockCapturer,
        countdown: MockCountdown? = nil
    ) -> CaptureScreenshotUseCase {
        CaptureScreenshotUseCase(permissions: permissions, selector: selector, capturer: capturer, countdown: countdown)
    }
}

@MainActor
struct AnnotationGeometryTests {
    private let style = AnnotationStyle(color: .red, lineWidth: 4, fill: false)

    @Test func lineHitTestUsesDistanceToSegment() {
        let line = EditorAnnotation(kind: .line(start: .zero, end: CGPoint(x: 100, y: 0)), style: style)

        #expect(line.hitTest(CGPoint(x: 50, y: 3), tolerance: 2))
        #expect(!line.hitTest(CGPoint(x: 50, y: 20), tolerance: 2))
    }

    @Test func outlinedRectangleIsOnlyHitOnItsBorder() {
        let rect = EditorAnnotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)

        #expect(rect.hitTest(CGPoint(x: 0, y: 50), tolerance: 3))
        #expect(!rect.hitTest(CGPoint(x: 50, y: 50), tolerance: 3))
    }

    @Test func resizingKeepsOppositeCorner() {
        let rect = EditorAnnotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 50)), style: style)
        let resized = rect.resized(handle: .bottomRight, to: CGPoint(x: 100, y: 80))

        #expect(resized.kind == .rectangle(CGRect(x: 10, y: 10, width: 90, height: 70)))
    }

    @Test func translationMovesEveryPoint() {
        let path = EditorAnnotation(kind: .freehand(points: [.zero, CGPoint(x: 5, y: 5)]), style: style)
        let moved = path.translated(by: CGSize(width: 10, height: -2))

        #expect(moved.kind == .freehand(points: [CGPoint(x: 10, y: -2), CGPoint(x: 15, y: 3)]))
    }

    @Test func countersAreNumberedInOrder() {
        let first = EditorAnnotation(kind: .counter(center: .zero), style: style)
        let arrow = EditorAnnotation(kind: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)), style: style)
        let second = EditorAnnotation(kind: .counter(center: CGPoint(x: 20, y: 20)), style: style)

        let numbers = AnnotationRenderer.counterNumbers(in: [first, arrow, second])

        #expect(numbers[first.id] == 1)
        #expect(numbers[second.id] == 2)
        #expect(numbers[arrow.id] == nil)
    }
}

@MainActor
struct RenderLayoutTests {
    @Test func backgroundAddsPaddingAroundCrop() {
        var document = EditorDocument()
        document.cropRect = CGRect(x: 100, y: 50, width: 200, height: 100)
        document.background.isEnabled = true
        document.background.padding = 20

        let layout = RenderLayout(document: document, imageSize: CGSize(width: 800, height: 600))

        #expect(layout.outputSize == CGSize(width: 240, height: 140))
        #expect(layout.toOutput(CGPoint(x: 100, y: 50)) == CGPoint(x: 20, y: 20))
        #expect(layout.toImage(CGPoint(x: 20, y: 20)) == CGPoint(x: 100, y: 50))
    }

    @Test func cropIsIgnoredWhileEditingIt() {
        var document = EditorDocument()
        document.cropRect = CGRect(x: 100, y: 50, width: 200, height: 100)

        let layout = RenderLayout(document: document, imageSize: CGSize(width: 800, height: 600), applyCropAndBackground: false)

        #expect(layout.outputSize == CGSize(width: 800, height: 600))
    }
}

@MainActor
struct EditorViewModelTests {
    @Test func drawingAnArrowAddsAndSelectsIt() {
        let viewModel = CaptureEditorViewModel(baseImage: NSImage(size: NSSize(width: 400, height: 300)))
        viewModel.activeTool = .arrow

        viewModel.pointerDown(at: CGPoint(x: 10, y: 10), tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: CGPoint(x: 120, y: 80), constrain: false)
        viewModel.pointerUp()

        #expect(viewModel.document.annotations.count == 1)
        #expect(viewModel.selectedID == viewModel.document.annotations.first?.id)

        viewModel.undo()
        #expect(viewModel.document.annotations.isEmpty)

        viewModel.redo()
        #expect(viewModel.document.annotations.count == 1)
    }

    @Test func movingWithSelectToolTranslatesAnnotation() {
        let viewModel = CaptureEditorViewModel(baseImage: NSImage(size: NSSize(width: 400, height: 300)))
        viewModel.activeTool = .rectangle
        viewModel.pointerDown(at: CGPoint(x: 10, y: 10), tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: CGPoint(x: 110, y: 60), constrain: false)
        viewModel.pointerUp()

        viewModel.activeTool = .select
        viewModel.pointerDown(at: CGPoint(x: 10, y: 30), tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: CGPoint(x: 30, y: 40), constrain: false)
        viewModel.pointerUp()

        #expect(viewModel.document.annotations.first?.kind == .rectangle(CGRect(x: 30, y: 20, width: 100, height: 50)))
    }

    @Test func changingColorUpdatesSelectedAnnotation() {
        let viewModel = CaptureEditorViewModel(baseImage: NSImage(size: NSSize(width: 400, height: 300)))
        viewModel.activeTool = .line
        viewModel.pointerDown(at: CGPoint(x: 10, y: 10), tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: CGPoint(x: 100, y: 10), constrain: false)
        viewModel.pointerUp()

        viewModel.strokeColor = .blue

        #expect(viewModel.document.annotations.first?.style.color == .blue)
    }

    @Test func cropIsAppliedWhenLeavingCropTool() {
        let viewModel = CaptureEditorViewModel(baseImage: NSImage(size: NSSize(width: 400, height: 300)))
        viewModel.activeTool = .crop
        viewModel.pointerDown(at: CGPoint(x: 50, y: 50), tolerance: 4, clickCount: 1)
        viewModel.pointerDragged(to: CGPoint(x: 250, y: 150), constrain: false)
        viewModel.pointerUp()
        viewModel.confirmCrop()

        #expect(viewModel.document.cropRect == CGRect(x: 50, y: 50, width: 200, height: 100))
        #expect(viewModel.layout.outputSize == CGSize(width: 200, height: 100))
    }
}

// MARK: - Mocks

private enum MockError: Error {
    case captureFailed
}

private final class MockPermissions: ScreenPermissionChecking {
    let preflight: Bool
    let requestResult: Bool

    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(preflight: Bool, requestResult: Bool) {
        self.preflight = preflight
        self.requestResult = requestResult
    }

    func hasScreenRecordingAccess() -> Bool {
        preflight
    }

    func requestScreenRecordingAccess() -> Bool {
        requestCount += 1
        return requestResult
    }

    func openScreenRecordingSettings() {
        openSettingsCount += 1
    }
}

private final class MockSelector: RegionSelecting {
    let selection: ScreenSelection?
    let frozenImage: NSImage?
    let display: ScreenSelection?
    private(set) var selectCount = 0

    init(selection: ScreenSelection?, frozenImage: NSImage? = nil, display: ScreenSelection? = nil) {
        self.selection = selection
        self.frozenImage = frozenImage
        self.display = display
    }

    func select(options _: SelectionOptions) async -> SelectionResult? {
        selectCount += 1
        return selection.map { SelectionResult(selection: $0, frozenImage: frozenImage) }
    }

    func displayUnderCursor() -> ScreenSelection? {
        display
    }
}

private final class MockCapturer: ScreenCaptureProviding {
    let result: Result<NSImage, Error>
    private(set) var captured: [ScreenSelection] = []

    init(result: Result<NSImage, Error>) {
        self.result = result
    }

    func displaySnapshots() async throws -> [CGDirectDisplayID: CGImage] {
        [:]
    }

    func capture(_ selection: ScreenSelection, options _: CaptureOptions) async throws -> NSImage {
        captured.append(selection)
        return try result.get()
    }
}

private final class MockCountdown: CountdownPresenting {
    let completes: Bool
    private(set) var requestedSeconds: Int?

    init(completes: Bool) {
        self.completes = completes
    }

    func countdown(seconds: Int, over _: ScreenSelection) async -> Bool {
        requestedSeconds = seconds
        return completes
    }
}
