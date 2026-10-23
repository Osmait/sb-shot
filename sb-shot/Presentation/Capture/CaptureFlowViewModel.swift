import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class CaptureFlowViewModel: ObservableObject {
    @Published private(set) var isCapturing = false

    private let useCase: CaptureScreenshotUseCase
    private let settings: AppSettings
    private let output: CaptureOutputHandler
    private let textRecognizer: TextRecognizing
    private let toast: ToastPresenting

    init(
        useCase: CaptureScreenshotUseCase,
        settings: AppSettings,
        output: CaptureOutputHandler,
        textRecognizer: TextRecognizing,
        toast: ToastPresenting
    ) {
        self.useCase = useCase
        self.settings = settings
        self.output = output
        self.textRecognizer = textRecognizer
        self.toast = toast
    }

    var hasPreviousArea: Bool {
        settings.lastCaptureArea != nil
    }

    func capture(_ mode: ScreenshotMode) {
        guard !isCapturing else { return }
        isCapturing = true

        Task {
            defer { isCapturing = false }

            let outcome = await useCase.execute(
                mode: mode,
                previousArea: settings.lastCaptureArea,
                selectionOptions: settings.selectionOptions,
                captureOptions: settings.captureOptions
            )
            handle(outcome)
        }
    }

    func captureText() {
        guard !isCapturing else { return }
        isCapturing = true

        Task {
            defer { isCapturing = false }

            var options = settings.selectionOptions
            options.purpose = .text
            options.allowsWindowMode = true

            let outcome = await useCase.execute(mode: .area, selectionOptions: options, captureOptions: CaptureOptions())
            guard case let .captured(image, _) = outcome else {
                handle(outcome)
                return
            }

            toast.showProgress("Reconociendo texto…")
            do {
                let text = try await textRecognizer.recognizeText(in: image)
                output.handleRecognizedText(text)
            } catch {
                toast.show("No se pudo reconocer el texto", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Abre una imagen del disco en el editor.
    func annotateImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Elige una imagen para anotar"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        output.openEditor(image)
    }

    private func handle(_ outcome: CaptureOutcome) {
        switch outcome {
        case let .captured(image, selection):
            if case let .area(rect) = selection {
                settings.lastCaptureArea = rect
            }
            output.handleScreenshot(image)
        case .cancelled:
            break
        case .permissionDenied:
            toast.show("Activa Grabación de pantalla en Ajustes del Sistema", systemImage: "lock.shield")
        case .failed:
            toast.show("No se pudo capturar", systemImage: "exclamationmark.triangle")
        }
    }
}
