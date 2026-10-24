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

        // The first time the system shows its own prompt; Settings is only opened on later attempts.
        let alreadyRequested = permissions.hasRequestedScreenRecordingAccess()
        guard permissions.requestScreenRecordingAccess() else {
            if alreadyRequested {
                permissions.openScreenRecordingSettings()
            }
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
                // The capture happens after the countdown, so the screen is not frozen.
                options.freezeScreen = false
            }
            options.hidesDesktopIcons = captureOptions.hideDesktopIcons

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
            return .captured(captureOptions.downscaleToOneX ? Self.downscaledToPoints(frozenImage) : frozenImage, selection)
        }

        do {
            let image = try await capturer.capture(selection, options: captureOptions)
            return .captured(image, selection)
        } catch {
            return .failed
        }
    }

    /// The frozen image is at Retina resolution; with `downscaleToOneX` it is scaled to one pixel per point.
    private static func downscaledToPoints(_ image: NSImage) -> NSImage {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        guard
            let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            source.width > width, width > 0, height > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace.renderable(for: source),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return image }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return image }
        return NSImage(cgImage: scaled, size: image.size)
    }
}
