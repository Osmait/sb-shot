import Foundation

@MainActor
final class AppContainer {
    private let permissionService = PermissionService()
    private let clipboardService = ClipboardService()
    private let captureService = ScreenCaptureService()
    private let selector = SelectionOverlayRegionSelector()
    private let previewPresenter = PreviewWindowPresenter()
    private let editorPresenter = EditorWindowPresenter()
    private let thumbnailPresenter = ThumbnailWindowPresenter()

    lazy var captureViewModel: CaptureFlowViewModel = {
        let useCase = CaptureRegionUseCase(
            permissions: permissionService,
            selector: selector,
            capturer: captureService,
            clipboard: clipboardService
        )

        return CaptureFlowViewModel(
            useCase: useCase,
            thumbnailPresenter: thumbnailPresenter,
            previewPresenter: previewPresenter,
            editorPresenter: editorPresenter,
            clipboard: clipboardService
        )
    }()
}
