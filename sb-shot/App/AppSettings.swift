import AppKit
import Combine

/// Preference stored in UserDefaults (as JSON) that notifies the `AppSettings` instance containing it.
@propertyWrapper
struct Preference<Value: Codable> {
    let key: String
    let defaultValue: Value
    fileprivate var cached: Value?

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    @available(*, unavailable, message: "Only usable inside AppSettings")
    var wrappedValue: Value {
        get { fatalError("Preference only works inside AppSettings") }
        set { fatalError("Preference only works inside AppSettings") } // swiftlint:disable:this unused_setter_value
    }

    static subscript(
        _enclosingInstance instance: AppSettings,
        wrapped _: ReferenceWritableKeyPath<AppSettings, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<AppSettings, Self>
    ) -> Value {
        get {
            let storage = instance[keyPath: storageKeyPath]
            if let cached = storage.cached {
                return cached
            }

            let value = instance.defaults.data(forKey: storage.key)
                .flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? storage.defaultValue
            instance[keyPath: storageKeyPath].cached = value
            return value
        }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].cached = newValue
            instance.defaults.set(try? JSONEncoder().encode(newValue), forKey: instance[keyPath: storageKeyPath].key)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    let defaults: UserDefaults

    /// Global shortcuts are disabled while a shortcut is being recorded in Settings.
    @Published var recordingShortcutFor: CaptureAction?

    /// Actions whose global shortcut could not be registered (in use by another app). Updated by `AppContainer`.
    @Published var unavailableShortcuts: Set<CaptureAction> = []

    // MARK: General

    @Preference("general.copyToClipboard") var copyToClipboard = true
    @Preference("general.showQuickAccess") var showQuickAccess = true
    @Preference("general.autoSave") var autoSave = false
    @Preference("general.openEditor") var openEditorAfterCapture = false
    @Preference("general.playSound") var playSound = true
    @Preference("general.imageFormat") var imageFormat = ImageFileFormat.png
    @Preference("general.filePrefix") var fileNamePrefix = "sb-shot"
    @Preference("general.keepHistory") var keepHistory = true

    // MARK: Capture

    @Preference("capture.freezeScreen") var freezeScreen = false
    @Preference("capture.showMagnifier") var showMagnifier = true
    @Preference("capture.showCrosshair") var showCrosshair = true
    @Preference("capture.windowShadow") var windowShadow = true
    @Preference("capture.hideDesktopIcons") var hideDesktopIcons = false
    @Preference("capture.downscaleRetina") var downscaleRetina = false
    @Preference("capture.lastArea") var lastCaptureArea: CGRect? = nil // swiftlint:disable:this implicit_optional_initialization

    // MARK: Recording

    @Preference("recording.format") var recordingFormat = RecordingFormat.mp4
    @Preference("recording.fps") var recordingFPS = 60
    @Preference("recording.showCursor") var recordingShowsCursor = true
    @Preference("recording.highlightClicks") var recordingHighlightsClicks = true
    @Preference("recording.systemAudio") var recordingSystemAudio = false
    @Preference("recording.microphone") var recordingMicrophone = false
    @Preference("recording.countdown") var recordingCountdown = 3
    @Preference("recording.retina") var recordingRetina = true
    @Preference("recording.gifFPS") var gifFPS = 15
    @Preference("recording.gifMaxWidth") var gifMaxWidth = 960.0

    // MARK: Quick Access

    @Preference("quickAccess.position") var quickAccessPosition = QuickAccessPosition.bottomRight
    @Preference("quickAccess.autoClose") var quickAccessAutoClose = 10
    @Preference("quickAccess.closeAfterDrag") var quickAccessClosesAfterDrag = true

    // MARK: Shortcuts

    /// Shortcut per action. A `nil` entry means the user disabled it.
    @Preference("shortcuts") private var storedShortcuts: [String: GlobalShortcut?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyShortcut()
    }

    func shortcut(for action: CaptureAction) -> GlobalShortcut? {
        if let stored = storedShortcuts[action.rawValue] {
            return stored
        }
        return action.defaultShortcut
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for action: CaptureAction) {
        var shortcuts = storedShortcuts
        shortcuts[action.rawValue] = .some(shortcut)

        // A shortcut can only belong to one action.
        if let shortcut {
            for other in CaptureAction.allCases where other != action && self.shortcut(for: other) == shortcut {
                shortcuts[other.rawValue] = .some(nil)
            }
        }
        storedShortcuts = shortcuts
    }

    func resetShortcuts() {
        storedShortcuts = [:]
    }

    var activeShortcuts: [CaptureAction: GlobalShortcut] {
        var result: [CaptureAction: GlobalShortcut] = [:]
        for action in CaptureAction.allCases {
            if let shortcut = shortcut(for: action) {
                result[action] = shortcut
            }
        }
        return result
    }

    // MARK: Derived options

    var selectionOptions: SelectionOptions {
        SelectionOptions(
            purpose: .screenshot,
            freezeScreen: freezeScreen,
            showsMagnifier: showMagnifier,
            showsCrosshair: showCrosshair
        )
    }

    var captureOptions: CaptureOptions {
        CaptureOptions(
            includeWindowShadow: windowShadow,
            hideDesktopIcons: hideDesktopIcons,
            downscaleToOneX: downscaleRetina
        )
    }

    var recordingOptions: RecordingOptions {
        RecordingOptions(
            format: recordingFormat,
            framesPerSecond: recordingFPS,
            showsCursor: recordingShowsCursor,
            highlightsClicks: recordingHighlightsClicks,
            capturesSystemAudio: recordingSystemAudio,
            capturesMicrophone: recordingMicrophone,
            countdownSeconds: recordingCountdown,
            retinaQuality: recordingRetina,
            gifFramesPerSecond: gifFPS,
            gifMaxWidth: gifMaxWidth
        )
    }

    private func migrateLegacyShortcut() {
        let legacyKey = "sbshot.globalShortcut"
        guard let data = defaults.data(forKey: legacyKey) else { return }
        defaults.removeObject(forKey: legacyKey)

        if let legacy = try? JSONDecoder().decode(GlobalShortcut?.self, from: data), legacy != CaptureAction.captureArea.defaultShortcut {
            setShortcut(legacy, for: .captureArea)
        }
    }
}
