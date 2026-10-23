import Combine
import Foundation

@MainActor
final class AppContainer {
    let shortcutSettingsStore = ShortcutSettingsStore()

    private let permissionService = PermissionService()
    private let clipboardService = ClipboardService()
    private let captureService = ScreenCaptureService()
    private let selector = SelectionOverlayRegionSelector()
    private let previewPresenter = PreviewWindowPresenter()
    private let editorPresenter = EditorWindowPresenter()
    private let thumbnailPresenter = ThumbnailWindowPresenter()
    private let hotkeyManager = HotkeyManager()
    private var cancellables = Set<AnyCancellable>()

    init() {
        bindHotkeySettings()
    }

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

    private func bindHotkeySettings() {
        hotkeyManager.onHotKeyPressed = { [weak self] in
            Task { @MainActor in
                self?.captureViewModel.captureRegion()
            }
        }

        shortcutSettingsStore.$shortcut
            .combineLatest(shortcutSettingsStore.$isRecordingShortcut)
            .sink { [weak self] shortcut, isRecording in
                self?.hotkeyManager.register(shortcut: isRecording ? nil : shortcut)
            }
            .store(in: &cancellables)
    }
}
