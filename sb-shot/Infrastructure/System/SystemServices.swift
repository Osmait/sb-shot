import AppKit
import ServiceManagement
import Vision

enum SoundPlayer {
    private static let captureSoundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    private static let captureSound: NSSound? = NSSound(contentsOfFile: captureSoundPath, byReference: true) ?? NSSound(named: "Tink")

    static func playCapture() {
        captureSound?.stop()
        captureSound?.play()
    }

    static func playRecordingStarted() {
        NSSound(named: "Pop")?.play()
    }
}

enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Enabled, or registered and waiting for the user to approve it in System Settings.
    static var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
    }
}

struct TextRecognitionService {
    enum RecognitionError: Error {
        case invalidImage
    }

    func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RecognitionError.invalidImage
        }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

extension TextRecognitionService: TextRecognizing {}
