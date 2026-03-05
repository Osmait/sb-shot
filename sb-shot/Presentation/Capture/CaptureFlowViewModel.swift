import Foundation
import AppKit
import Combine

@MainActor
final class CaptureFlowViewModel: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published var statusMessage: String?

    private var statusTask: Task<Void, Never>?

    private let useCase: CaptureRegionUseCase
    private let thumbnailPresenter: ThumbnailPresenting
    private let previewPresenter: PreviewPresenting
    private let editorPresenter: EditorPresenting
    private let clipboard: ClipboardWriting

    init(
        useCase: CaptureRegionUseCase,
        thumbnailPresenter: ThumbnailPresenting,
        previewPresenter: PreviewPresenting,
        editorPresenter: EditorPresenting,
        clipboard: ClipboardWriting
    ) {
        self.useCase = useCase
        self.thumbnailPresenter = thumbnailPresenter
        self.previewPresenter = previewPresenter
        self.editorPresenter = editorPresenter
        self.clipboard = clipboard
    }

    func captureRegion() {
        guard !isCapturing else { return }

        isCapturing = true
        setStatus(nil)

        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCase.execute()

            await MainActor.run {
                self.handleOutcome(outcome)
            }
        }
    }

    private func handleOutcome(_ outcome: CaptureRegionOutcome) {
        defer { isCapturing = false }

        switch outcome {
        case .captured(let image):
            presentThumbnail(image: image)
            setStatus("Captura copiada")
        case .cancelled:
            setStatus("Captura cancelada")
        case .permissionDenied:
            setStatus("Activa Screen Recording en Ajustes")
        case .failed:
            setStatus("No se pudo capturar")
        }
    }

    private func presentPreview(image: NSImage) {
        previewPresenter.show(
            image: image,
            onCopy: { [weak self] in
                self?.clipboard.copy(image: image)
                self?.setStatus("Captura copiada")
            },
            onEdit: { [weak self] in
                self?.presentEditor(image: image)
            }
        )
    }

    private func presentEditor(image: NSImage) {
        editorPresenter.show(image: image) { [weak self] editedImage in
            self?.clipboard.copy(image: editedImage)
            self?.setStatus("Captura editada copiada")
        }
    }

    private func presentThumbnail(image: NSImage) {
        thumbnailPresenter.show(
            image: image,
            onOpen: { [weak self] in
                self?.presentPreview(image: image)
            },
            onEdit: { [weak self] in
                self?.presentEditor(image: image)
            },
            onCopy: { [weak self] in
                self?.clipboard.copy(image: image)
                self?.setStatus("Captura copiada")
            }
        )
    }

    private func setStatus(_ message: String?) {
        statusTask?.cancel()
        statusMessage = message

        guard message != nil else { return }

        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.statusMessage = nil
            }
        }
    }
}
