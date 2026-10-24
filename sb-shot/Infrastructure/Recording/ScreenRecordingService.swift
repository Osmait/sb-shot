import AVFoundation
import ScreenCaptureKit

/// Records an area, a display or a window to MP4 with ScreenCaptureKit (`SCRecordingOutput`).
final class ScreenRecordingService: NSObject {
    enum RecordingError: LocalizedError {
        case alreadyRecording
        case notRecording
        case targetNotFound
        case emptyArea
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: String(localized: "A recording is already in progress")
            case .notRecording: String(localized: "There is no active recording")
            case .targetNotFound: String(localized: "The display or window to record could not be found")
            case .emptyArea: String(localized: "The selected area is too small")
            case let .failed(error): error?.localizedDescription ?? String(localized: "The recording failed")
            }
        }
    }

    /// Called if the recording stops on its own (for example, when the recorded window is closed).
    var onUnexpectedStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var isStopping = false
    /// File result, if the delegate reports it before anyone awaits `stop()`.
    private var finishResult: Result<Void, Error>?
    /// The stream already stopped on its own; `stopCapture()` would fail.
    private var streamDidStop = false
    private var didReportUnexpectedStop = false
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
            .appendingPathComponent("recording-\(UUID().uuidString).mp4")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = .h264

        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        // ScreenCaptureKit warns if there is no output per sample type, even when only SCRecordingOutput is used.
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
        finishResult = nil
        streamDidStop = false
        didReportUnexpectedStop = false

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
        // Always release the session, even on failure, so the next recording can start.
        defer { reset() }

        do {
            if let finishResult {
                // The file is already closed (for example, the recorded window was closed).
                try finishResult.get()
            } else {
                let alreadyStopped = streamDidStop
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    finishContinuation = continuation
                    stopFallbackTask = Task { [weak self] in
                        if !alreadyStopped {
                            try? await stream.stopCapture()
                        }
                        // If the delegate never confirms the file was closed, continue after a reasonable wait.
                        try? await Task.sleep(nanoseconds: alreadyStopped ? 3_000_000_000 : 10_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.resumeFinish(with: nil)
                    }
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
        if !streamDidStop {
            try? await stream.stopCapture()
        }
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        resumeFinish(with: nil)
        reset()
    }

    // MARK: - Private

    /// Newly created windows take a moment to show up in `SCShareableContent`.
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
        /// Display region to record (in display-local coordinates), or `nil` for all content.
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

    /// Excludes the whole app (control bar, border, toasts shown later) instead of individual windows,
    /// because newly created windows may not be listed in `SCShareableContent` yet.
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

    /// H.264 requires even dimensions and has a practical 4K limit.
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
        guard let continuation = finishContinuation else {
            // Nobody is waiting yet: store it so `stop()` finishes without waiting for the fallback.
            if stream != nil, finishResult == nil {
                finishResult = error.map { .failure($0) } ?? .success(())
            }
            return
        }
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
        finishResult = nil
        streamDidStop = false
        didReportUnexpectedStop = false
    }

    private func isCurrent(stream id: ObjectIdentifier) -> Bool {
        stream.map(ObjectIdentifier.init) == id
    }

    private func isCurrent(output id: ObjectIdentifier) -> Bool {
        recordingOutput.map(ObjectIdentifier.init) == id
    }

    /// Reports only once per session, even if both the stream and the output fail.
    private func handleUnexpectedStop(_ error: Error?) {
        guard !isStopping, stream != nil, !didReportUnexpectedStop else { return }
        didReportUnexpectedStop = true
        onUnexpectedStop?(error)
    }
}

extension ScreenRecordingService: ScreenRecording {}

extension ScreenRecordingService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let id = ObjectIdentifier(stream)
        Task { @MainActor in
            // Ignore late callbacks from a previous session (for example, after a restart).
            guard self.isCurrent(stream: id) else { return }
            self.streamDidStop = true
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
            self.handleUnexpectedStop(nil)
        }
    }

    nonisolated func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        let id = ObjectIdentifier(output)
        Task { @MainActor in
            guard self.isCurrent(output: id) else { return }
            self.resumeFinish(with: error)
            self.handleUnexpectedStop(error)
        }
    }
}

/// Empty output: `SCRecordingOutput` writes the frames straight to the file.
private final nonisolated class StreamSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.burgos.sb-shot.stream-sink")

    func stream(_: SCStream, didOutputSampleBuffer _: CMSampleBuffer, of _: SCStreamOutputType) {}
}
