import AppKit
import Combine

@MainActor
final class RecordingViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case processing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    private let useCase: CaptureScreenshotUseCase
    private let permissions: PermissionService
    private let selector: RegionSelecting
    private let recorder: ScreenRecording
    private let controls: RecordingControlsPresenting
    private let countdown: CountdownPresenting
    private let clickHighlighter: ClickHighlighter
    private let settings: AppSettings
    private let output: CaptureOutputHandler
    private let toast: ToastPresenting

    private var lastSelection: ScreenSelection?
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?

    init(
        useCase: CaptureScreenshotUseCase,
        permissions: PermissionService,
        selector: RegionSelecting,
        recorder: ScreenRecording,
        controls: RecordingControlsPresenting,
        countdown: CountdownPresenting,
        clickHighlighter: ClickHighlighter,
        settings: AppSettings,
        output: CaptureOutputHandler,
        toast: ToastPresenting
    ) {
        self.useCase = useCase
        self.permissions = permissions
        self.selector = selector
        self.recorder = recorder
        self.controls = controls
        self.countdown = countdown
        self.clickHighlighter = clickHighlighter
        self.settings = settings
        self.output = output
        self.toast = toast

        recorder.onUnexpectedStop = { [weak self] _ in
            self?.stop()
        }
    }

    var isRecording: Bool {
        state == .recording
    }

    var isBusy: Bool {
        state != .idle
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Inicia una grabacion o detiene la que esta en curso (el mismo atajo hace las dos cosas).
    func toggle(fullscreen: Bool) {
        switch state {
        case .recording: stop()
        case .idle: start(fullscreen: fullscreen)
        case .preparing, .processing: break
        }
    }

    func start(fullscreen: Bool) {
        guard state == .idle else { return }
        state = .preparing

        Task {
            guard useCase.ensurePermission() else {
                toast.show("Activa Grabación de pantalla en Ajustes del Sistema", systemImage: "lock.shield")
                state = .idle
                return
            }

            let selection: ScreenSelection?
            if fullscreen {
                selection = selector.displayUnderCursor()
            } else {
                var options = settings.selectionOptions
                options.purpose = .recording
                options.freezeScreen = false
                selection = await selector.select(options: options)?.selection
            }

            guard let selection else {
                state = .idle
                return
            }

            lastSelection = selection
            await begin(selection, countdownSeconds: settings.recordingCountdown)
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .processing
        tearDownSession()

        Task {
            do {
                let url = try await recorder.stop()
                await output.handleRecording(url)
            } catch {
                toast.show("No se pudo guardar la grabación", systemImage: "exclamationmark.triangle")
            }
            state = .idle
        }
    }

    func cancel() {
        guard state == .recording else { return }
        state = .processing
        tearDownSession()

        Task {
            await recorder.cancel()
            toast.show("Grabación descartada", systemImage: "trash")
            state = .idle
        }
    }

    func restart() {
        guard state == .recording, let selection = lastSelection else { return }
        state = .preparing
        tearDownSession()

        Task {
            await recorder.cancel()
            await begin(selection, countdownSeconds: settings.recordingCountdown)
        }
    }

    // MARK: - Private

    private func begin(_ selection: ScreenSelection, countdownSeconds: Int) async {
        var options = settings.recordingOptions

        if options.capturesMicrophone, await !(permissions.requestMicrophoneAccess()) {
            options.capturesMicrophone = false
            toast.show("Sin acceso al micrófono: se graba sin voz", systemImage: "mic.slash")
        }

        if countdownSeconds > 0 {
            guard await countdown.countdown(seconds: countdownSeconds, over: selection) else {
                state = .idle
                return
            }
        }

        // En grabaciones de ventana solo se captura esa ventana, asi que el resaltado no se veria.
        if case .window = selection {
            options.highlightsClicks = false
        }
        if options.highlightsClicks {
            clickHighlighter.start()
        }

        controls.show(
            for: selection,
            onStop: { [weak self] in self?.stop() },
            onRestart: { [weak self] in self?.restart() },
            onCancel: { [weak self] in self?.cancel() }
        )

        do {
            try await recorder.start(selection, options: options, visibleOwnWindowNumbers: clickHighlighter.windowNumbers)
        } catch {
            tearDownSession()
            state = .idle
            toast.show(error.localizedDescription, systemImage: "exclamationmark.triangle")
            return
        }

        if settings.playSound {
            SoundPlayer.playRecordingStarted()
        }

        startedAt = Date()
        elapsed = 0
        state = .recording
        startTimer()
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let startedAt else { return }
                elapsed = Date().timeIntervalSince(startedAt)
                controls.update(elapsed: elapsed)
            }
        }
    }

    private func tearDownSession() {
        timerTask?.cancel()
        timerTask = nil
        controls.hide()
        clickHighlighter.stop()
    }
}
