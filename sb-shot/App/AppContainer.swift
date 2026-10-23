import Combine
import Foundation

@MainActor
final class AppContainer {
    let settings = AppSettings()
    let fileStorage = FileStorage()
    let history = HistoryStore()

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
        fileStorage.onSaveFolderUnavailable = { [weak self] in
            // Diferido: puede ocurrir durante el arranque, antes de que la app pueda mostrar ventanas.
            Task { @MainActor in
                self?.toast.show("La carpeta de guardado ya no está disponible; se usará la predeterminada", systemImage: "folder.badge.questionmark")
            }
        }
        // Resuelve la carpeta al arrancar para avisar enseguida si ya no existe.
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

        // Mientras se graba un atajo todos estan desactivados a proposito; se conserva el estado anterior.
        // Solo se publica si cambia, porque cada cambio vuelve a llamar a este metodo.
        guard !isRecordingShortcut, settings.unavailableShortcuts != hotkeyManager.failedActions else { return }
        settings.unavailableShortcuts = hotkeyManager.failedActions
    }
}
