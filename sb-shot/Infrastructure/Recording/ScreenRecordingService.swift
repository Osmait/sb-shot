import AVFoundation
import ScreenCaptureKit

/// Graba un area, una pantalla o una ventana a MP4 con ScreenCaptureKit (`SCRecordingOutput`).
final class ScreenRecordingService: NSObject {
    enum RecordingError: LocalizedError {
        case alreadyRecording
        case notRecording
        case targetNotFound
        case emptyArea
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "Ya hay una grabación en curso"
            case .notRecording: "No hay ninguna grabación activa"
            case .targetNotFound: "No se encontró la pantalla o ventana a grabar"
            case .emptyArea: "El área seleccionada es demasiado pequeña"
            case let .failed(error): error?.localizedDescription ?? "La grabación falló"
            }
        }
    }

    /// Se llama si la grabacion se detiene sola (por ejemplo, si se cierra la ventana grabada).
    var onUnexpectedStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var isStopping = false
    private var stopFallbackTask: Task<Void, Never>?
    private let sink = StreamSink()

    private static let maxPixelSize = CGSize(width: 3840, height: 2160)

    func start(_ selection: ScreenSelection, options: RecordingOptions, visibleOwnWindowNumbers: [Int]) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }

        let content = try await shareableContent(waitingFor: visibleOwnWindowNumbers)
        let target = try makeTarget(for: selection, content: content, visibleOwnWindowNumbers: visibleOwnWindowNumbers)
        let filter = target.filter

        let scale = options.retinaQuality ? CGFloat(filter.pointPixelScale) : 1
        let pixelSize = Self.evenPixelSize(for: target.pointSize, scale: scale)

        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        if let sourceRect = target.sourceRect {
            config.sourceRect = sourceRect
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(options.framesPerSecond, 1)))
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        config.capturesAudio = options.capturesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.captureMicrophone = options.capturesMicrophone
        config.colorSpaceName = CGColorSpace.sRGB

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-shot", isDirectory: true)
            .appendingPathComponent("grabacion-\(UUID().uuidString).mp4")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // ScreenCaptureKit avisa si no hay una salida por tipo de muestra, aunque solo se use SCRecordingOutput.
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        if options.capturesSystemAudio {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        }
        if options.capturesMicrophone {
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        }
        try stream.addRecordingOutput(output)

        self.stream = stream
        recordingOutput = output
        outputURL = url
        isStopping = false

        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw RecordingError.failed(error)
        }
    }

    func stop() async throws -> URL {
        guard let stream, let url = outputURL else { throw RecordingError.notRecording }
        isStopping = true
        // Siempre se libera la sesion, incluso si falla, para que la siguiente grabacion pueda empezar.
        defer { reset() }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finishContinuation = continuation
                stopFallbackTask = Task { [weak self] in
                    try? await stream.stopCapture()
                    // Si el delegado no confirma el cierre del archivo, se continua tras una espera prudente.
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.resumeFinish(with: nil)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.failed(error)
        }

        guard await (try? AVURLAsset(url: url).load(.isPlayable)) == true else {
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.failed(nil)
        }
        return url
    }

    func cancel() async {
        guard let stream else { return }
        isStopping = true
        try? await stream.stopCapture()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        resumeFinish(with: nil)
        reset()
    }

    // MARK: - Private

    /// Las ventanas recien creadas tardan un momento en aparecer en `SCShareableContent`.
    private func shareableContent(waitingFor windowNumbers: [Int]) async throws -> SCShareableContent {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0 ..< 10 {
            let listed = Set(content.windows.map { Int($0.windowID) })
            if windowNumbers.allSatisfy(listed.contains) {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        return content
    }

    private struct CaptureTarget {
        let filter: SCContentFilter
        /// Region de la pantalla a grabar (coordenadas locales de la pantalla), o `nil` para todo el contenido.
        let sourceRect: CGRect?
        let pointSize: CGSize
    }

    private func makeTarget(
        for selection: ScreenSelection,
        content: SCShareableContent,
        visibleOwnWindowNumbers: [Int]
    ) throws -> CaptureTarget {
        switch selection {
        case let .window(id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordingError.targetNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return CaptureTarget(filter: filter, sourceRect: nil, pointSize: window.frame.size)

        case let .display(id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingError.targetNotFound
            }
            let filter = displayFilter(display, content: content, visibleOwnWindowNumbers: visibleOwnWindowNumbers)
            return CaptureTarget(filter: filter, sourceRect: nil, pointSize: display.frame.size)

        case let .area(rect):
            let cgRect = ScreenGeometry.toCoreGraphics(rect.standardized.integral)
            let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
            guard
                let display = content.displays.first(where: { $0.frame.contains(center) })
                ?? content.displays.first(where: { $0.frame.intersects(cgRect) })
            else { throw RecordingError.targetNotFound }

            let clipped = cgRect.intersection(display.frame)
            guard clipped.width >= 2, clipped.height >= 2 else { throw RecordingError.emptyArea }

            let sourceRect = CGRect(
                x: clipped.minX - display.frame.minX,
                y: clipped.minY - display.frame.minY,
                width: clipped.width,
                height: clipped.height
            )
            let filter = displayFilter(display, content: content, visibleOwnWindowNumbers: visibleOwnWindowNumbers)
            return CaptureTarget(filter: filter, sourceRect: sourceRect, pointSize: clipped.size)
        }
    }

    /// Excluye la app completa (barra de control, borde, avisos que aparezcan despues) en lugar de ventanas
    /// sueltas, porque las ventanas recien creadas pueden no figurar todavia en `SCShareableContent`.
    private func displayFilter(_ display: SCDisplay, content: SCShareableContent, visibleOwnWindowNumbers: [Int]) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let visible = content.windows.filter { visibleOwnWindowNumbers.contains(Int($0.windowID)) }

        if let ownApp = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: visible)
        }

        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && !visibleOwnWindowNumbers.contains(Int($0.windowID))
        }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    /// H.264 exige dimensiones pares y tiene un limite practico de 4K.
    private static func evenPixelSize(for pointSize: CGSize, scale: CGFloat) -> CGSize {
        var width = pointSize.width * scale
        var height = pointSize.height * scale

        let ratio = min(maxPixelSize.width / max(width, 1), maxPixelSize.height / max(height, 1), 1)
        width *= ratio
        height *= ratio

        return CGSize(
            width: max(CGFloat(Int(width) / 2 * 2), 2),
            height: max(CGFloat(Int(height) / 2 * 2), 2)
        )
    }

    private func resumeFinish(with error: Error?) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func reset() {
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        stream = nil
        recordingOutput = nil
        outputURL = nil
        isStopping = false
    }

    private func isCurrent(stream id: ObjectIdentifier) -> Bool {
        stream.map(ObjectIdentifier.init) == id
    }

    private func isCurrent(output id: ObjectIdentifier) -> Bool {
        recordingOutput.map(ObjectIdentifier.init) == id
    }

    private func handleUnexpectedStop(_ error: Error?) {
        guard !isStopping, stream != nil else { return }
        resumeFinish(with: error)
        onUnexpectedStop?(error)
    }
}

extension ScreenRecordingService: ScreenRecording {}

extension ScreenRecordingService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let id = ObjectIdentifier(stream)
        Task { @MainActor in
            // Ignora avisos tardios de una sesion anterior (por ejemplo, despues de reiniciar).
            guard self.isCurrent(stream: id) else { return }
            self.handleUnexpectedStop(error)
        }
    }
}

extension ScreenRecordingService: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        let id = ObjectIdentifier(output)
        Task { @MainActor in
            guard self.isCurrent(output: id) else { return }
            self.resumeFinish(with: nil)
        }
    }

    nonisolated func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        let id = ObjectIdentifier(output)
        Task { @MainActor in
            guard self.isCurrent(output: id) else { return }
            if self.isStopping {
                self.resumeFinish(with: error)
            } else {
                self.handleUnexpectedStop(error)
            }
        }
    }
}

/// Salida vacia: los frames los escribe `SCRecordingOutput` directamente al archivo.
private final nonisolated class StreamSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.burgos.sb-shot.stream-sink")

    func stream(_: SCStream, didOutputSampleBuffer _: CMSampleBuffer, of _: SCStreamOutputType) {}
}
