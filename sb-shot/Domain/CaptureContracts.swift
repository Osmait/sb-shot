import AppKit

enum CaptureRegionOutcome {
    case captured(NSImage)
    case cancelled
    case permissionDenied
    case failed
}

protocol ScreenCaptureProviding {
    func captureRegion(_ rect: CGRect) async throws -> NSImage
}

protocol ScreenPermissionChecking {
    func hasScreenRecordingAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
    func openScreenRecordingSettings()
}

protocol ClipboardWriting {
    func copy(image: NSImage)
}

protocol RegionSelecting {
    func selectRegion() async -> CGRect?
}
