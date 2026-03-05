import Foundation

struct CaptureRegionUseCase {
    let permissions: ScreenPermissionChecking
    let selector: RegionSelecting
    let capturer: ScreenCaptureProviding
    let clipboard: ClipboardWriting

    func execute() async -> CaptureRegionOutcome {
        if !permissions.hasScreenRecordingAccess() {
            let granted = permissions.requestScreenRecordingAccess()
            guard granted else {
                permissions.openScreenRecordingSettings()
                return .permissionDenied
            }
        }

        guard let selection = await selector.selectRegion() else {
            return .cancelled
        }

        do {
            let image = try await capturer.captureRegion(selection)
            clipboard.copy(image: image)
            return .captured(image)
        } catch {
            return .failed
        }
    }
}
