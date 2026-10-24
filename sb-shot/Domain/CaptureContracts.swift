import AppKit

enum CaptureOutcome {
    case captured(NSImage, ScreenSelection)
    case cancelled
    case permissionDenied
    case failed
}

protocol ScreenCaptureProviding {
    /// Captures each full display (without the app's windows) for the magnifier and frozen mode.
    func displaySnapshots() async throws -> [CGDirectDisplayID: CGImage]
    /// Same as `displaySnapshots()`, but can hide the desktop icons (frozen mode).
    func displaySnapshots(hidingDesktopIcons: Bool) async throws -> [CGDirectDisplayID: CGImage]
    func capture(_ selection: ScreenSelection, options: CaptureOptions) async throws -> NSImage
}

extension ScreenCaptureProviding {
    func displaySnapshots(hidingDesktopIcons _: Bool) async throws -> [CGDirectDisplayID: CGImage] {
        try await displaySnapshots()
    }
}

protocol ScreenPermissionChecking {
    func hasScreenRecordingAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
    func openScreenRecordingSettings()
    /// `true` if the system prompt was already shown before; the first time, Settings is not opened.
    func hasRequestedScreenRecordingAccess() -> Bool
}

extension ScreenPermissionChecking {
    func hasRequestedScreenRecordingAccess() -> Bool {
        true
    }
}

protocol ClipboardWriting {
    func copy(image: NSImage)
    func copy(text: String)
    func copy(fileURL: URL)
}

protocol RegionSelecting {
    func select(options: SelectionOptions) async -> SelectionResult?
    /// Display under the cursor, for fullscreen captures or recordings.
    func displayUnderCursor() -> ScreenSelection?
}

protocol CountdownPresenting: AnyObject {
    /// Shows a countdown over the selection. Returns `false` if the user cancels it.
    func countdown(seconds: Int, over selection: ScreenSelection) async -> Bool
}

protocol ScreenRecording: AnyObject {
    var onUnexpectedStop: ((Error?) -> Void)? { get set }
    /// Records without any of the app's windows, except `visibleOwnWindowNumbers` (for example, the click highlight).
    func start(_ selection: ScreenSelection, options: RecordingOptions, visibleOwnWindowNumbers: [Int]) async throws
    func stop() async throws -> URL
    func cancel() async
}

protocol TextRecognizing {
    func recognizeText(in image: NSImage) async throws -> String
}
