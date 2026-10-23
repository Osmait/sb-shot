import AppKit

struct CaptureScreenshotUseCase {
    let permissions: ScreenPermissionChecking
    let selector: RegionSelecting
    let capturer: ScreenCaptureProviding
    let countdown: CountdownPresenting?

    func ensurePermission() -> Bool {
        if permissions.hasScreenRecordingAccess() {
            return true
        }

        guard permissions.requestScreenRecordingAccess() else {
            permissions.openScreenRecordingSettings()
            return false
        }
        return true
    }

    // swiftlint:disable:next cyclomatic_complexity
    func execute(
        mode: ScreenshotMode,
        previousArea: CGRect? = nil,
        selectionOptions: SelectionOptions = SelectionOptions(),
        captureOptions: CaptureOptions = CaptureOptions()
    ) async -> CaptureOutcome {
        guard ensurePermission() else {
            return .permissionDenied
        }

        var frozenImage: NSImage?
        let selection: ScreenSelection

        switch mode {
        case .fullscreen:
            guard let display = selector.displayUnderCursor() else { return .failed }
            selection = display

        case .previousArea where previousArea != nil:
            selection = .area(previousArea ?? .zero)

        case .area, .previousArea, .window, .timed:
            var options = selectionOptions
            options.startInWindowMode = mode == .window
            if case .timed = mode {
                // La captura se hace despues de la cuenta regresiva, asi que no se congela la pantalla.
                options.freezeScreen = false
            }

            guard let result = await selector.select(options: options) else {
                return .cancelled
            }
            selection = result.selection
            frozenImage = result.frozenImage
        }

        if case let .timed(seconds) = mode, seconds > 0 {
            let completed = await countdown?.countdown(seconds: seconds, over: selection) ?? true
            guard completed else { return .cancelled }
        }

        if let frozenImage {
            return .captured(frozenImage, selection)
        }

        do {
            let image = try await capturer.capture(selection, options: captureOptions)
            return .captured(image, selection)
        } catch {
            return .failed
        }
    }
}
