import Combine
import Foundation

@MainActor
final class AppContainer {
    #if DEBUG
    // Demo mode never reads or writes the user's real settings, files or history.
    let settings = AppSettings(defaults: DemoMode.defaults ?? .standard)
    let fileStorage = FileStorage(defaults: DemoMode.defaults ?? .standard, temporaryDirectory: DemoMode.directory("files"))
    let history = HistoryStore(directory: DemoMode.directory("container-history"))
    #else
    let settings = AppSettings()
    let fileStorage = FileStorage()
    let history = HistoryStore()
    #endif

    private let permissionService = PermissionService()
    private let clipboardService = ClipboardService()
    private let captureService = ScreenCaptureService()
    private let recordingService = ScreenRecordingService()
    private let hotkeyManager = HotkeyManager()
    private let toast = ToastController()
    private let countdown = CountdownController()
    private var cancellables = Set<AnyCancellable>()

    private lazy var selector = SelectionOverlayRegionSelector(capturer: captureService)

    private lazy var useCase = CaptureScreenshotUseCase(
        permissions: permissionService,
        selector: selector,
        capturer: captureService,
        countdown: countdown
    )

    lazy var outputHandler = CaptureOutputHandler(
        settings: settings,
        clipboard: clipboardService,
        files: fileStorage,
        history: history,
        quickAccess: QuickAccessController(settings: settings),
        editor: EditorWindowPresenter(),
        videoEditor: VideoEditorWindowPresenter(),
        pins: PinnedImagePresenter(toast: toast),
        toast: toast
    )

    lazy var captureViewModel = CaptureFlowViewModel(
        useCase: useCase,
        settings: settings,
        output: outputHandler,
        textRecognizer: TextRecognitionService(),
        toast: toast
    )

    lazy var recordingViewModel = RecordingViewModel(
        useCase: useCase,
        permissions: permissionService,
        selector: selector,
        recorder: recordingService,
        controls: RecordingControlsController(),
        countdown: countdown,
        clickHighlighter: ClickHighlighter(),
        settings: settings,
        output: outputHandler,
        toast: toast
    )

    lazy var historyPresenter: HistoryPresenting = HistoryWindowPresenter(
        store: history,
        actions: HistoryActions(
            open: { [weak self] entry, url in self?.outputHandler.openHistoryEntry(entry, url: url) },
            copy: { [weak self] entry, url in self?.outputHandler.copyHistoryEntry(entry, url: url) },
            reveal: { [weak self] url in self?.outputHandler.reveal(url) }
        )
    )

    init() {
        #if DEBUG
        // Demo mode stages its own windows: no hotkeys and no cleanup of real files.
        if DemoMode.isActive {
            return
        }
        #endif
        fileStorage.onSaveFolderUnavailable = { [weak self] in
            // Deferred: this can happen during launch, before the app can show windows.
            Task { @MainActor in
                self?.toast.show(String(localized: "The save folder is no longer available; using the default folder"), systemImage: "folder.badge.questionmark")
            }
        }
        // Resolve the folder at launch to warn right away if it no longer exists.
        _ = fileStorage.saveFolder
        fileStorage.removeStaleTemporaryFiles()
        bindHotkeys()
    }

    func perform(_ action: CaptureAction) {
        switch action {
        case .captureArea: captureViewModel.capture(.area)
        case .capturePreviousArea: captureViewModel.capture(.previousArea)
        case .captureFullscreen: captureViewModel.capture(.fullscreen)
        case .captureWindow: captureViewModel.capture(.window)
        case .captureText: captureViewModel.captureText()
        case .recordArea: recordingViewModel.toggle(fullscreen: false)
        case .recordFullscreen: recordingViewModel.toggle(fullscreen: true)
        case .openHistory: historyPresenter.show()
        }
    }

    private func bindHotkeys() {
        hotkeyManager.onHotKeyPressed = { [weak self] action in
            Task { @MainActor in
                self?.perform(action)
            }
        }

        registerHotkeys()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.registerHotkeys() }
            .store(in: &cancellables)
    }

    private func registerHotkeys() {
        let isRecordingShortcut = settings.recordingShortcutFor != nil
        hotkeyManager.register(isRecordingShortcut ? [:] : settings.activeShortcuts)

        // While a shortcut is being recorded all of them are disabled on purpose; keep the previous state.
        // Only publish on change, because every change calls this method again.
        guard !isRecordingShortcut, settings.unavailableShortcuts != hotkeyManager.failedActions else { return }
        settings.unavailableShortcuts = hotkeyManager.failedActions
    }
}
