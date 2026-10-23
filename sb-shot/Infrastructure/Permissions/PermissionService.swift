import AppKit
import AVFoundation

struct PermissionService {
    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static let requestedKey = "didRequestScreenRecordingAccess"

    func requestScreenRecordingAccess() -> Bool {
        UserDefaults.standard.set(true, forKey: Self.requestedKey)
        return CGRequestScreenCaptureAccess()
    }

    func hasRequestedScreenRecordingAccess() -> Bool {
        UserDefaults.standard.bool(forKey: Self.requestedKey)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }
}

extension PermissionService: ScreenPermissionChecking {}
