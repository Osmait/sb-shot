import AppKit
@testable import SbShot
import Testing

@MainActor
private final class FakeClipboard: ImageFileClipboardWriting {
    var pngCopies: [(data: Data, fileURL: URL?)] = []
    func copy(pngData: Data, fileURL: URL?) { pngCopies.append((pngData, fileURL)) }
    func copyImageFile(at _: URL) -> Bool { true }
    func copy(image _: NSImage) {}
    func copy(text _: String) {}
    func copy(fileURL _: URL) {}
}

@MainActor
private final class FakeQuickAccess: QuickAccessPresenting {
    var shown: [(item: CaptureItem, actions: QuickAccessActions)] = []
    func show(_ item: CaptureItem, actions: QuickAccessActions) { shown.append((item, actions)) }
    func dismiss(itemID _: UUID) {}
}

@MainActor
private final class FakeEditor: EditorPresenting {
    func show(image _: NSImage, actions _: EditorActions) {}
}

@MainActor
private final class FakeVideoEditor: VideoEditorPresenting {
    func show(videoURL _: URL, actions _: VideoEditorActions) {}
}

@MainActor
private final class FakePins: PinPresenting {
    func pin(image _: NSImage, onEdit _: @escaping (NSImage) -> Void, onCopy _: @escaping (NSImage) -> Void) {}
}

@MainActor
private final class FakeToast: ToastPresenting {
    var messages: [String] = []
    func show(_ message: String, systemImage _: String) { messages.append(message) }
    func showProgress(_ message: String) { messages.append(message) }
    func hide() {}
}

@MainActor
private final class Harness {
    let root: URL
    let tempDir: URL
    let saveDir: URL
    let historyDir: URL
    let suite = "sbshot.tests.output.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettings
    let files: FileStorage
    let history: HistoryStore
    let clipboard = FakeClipboard()
    let quickAccess = FakeQuickAccess()
    let toast = FakeToast()
    let handler: CaptureOutputHandler

    /// `brokenTemp` makes writing to the temporary folder impossible (its path hangs off a regular file).
    init(customSaveFolder: Bool, brokenTemp: Bool = false) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("sbshot-tests-output-\(UUID().uuidString)", isDirectory: true)
        saveDir = root.appendingPathComponent("saved", isDirectory: true)
        historyDir = root.appendingPathComponent("history", isDirectory: true)
        try fm.createDirectory(at: saveDir, withIntermediateDirectories: true)
        if brokenTemp {
            let blocker = root.appendingPathComponent("blocker")
            try Data([0]).write(to: blocker)
            tempDir = blocker.appendingPathComponent("tmp", isDirectory: true)
        } else {
            tempDir = root.appendingPathComponent("tmp", isDirectory: true)
        }

        defaults = UserDefaults(suiteName: suite)!
        if customSaveFolder {
            let bookmark = try saveDir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: "sbshot.saveFolderBookmark")
        }
        settings = AppSettings(defaults: defaults)
        settings.playSound = false
        settings.copyToClipboard = true
        settings.showQuickAccess = true
        settings.keepHistory = true
        settings.autoSave = false
        settings.openEditorAfterCapture = false
        files = FileStorage(defaults: defaults, temporaryDirectory: tempDir)
        history = HistoryStore(directory: historyDir)
        handler = CaptureOutputHandler(
            settings: settings, clipboard: clipboard, files: files, history: history,
            quickAccess: quickAccess, editor: FakeEditor(), videoEditor: FakeVideoEditor(),
            pins: FakePins(), toast: toast
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    func savedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: saveDir.path)) ?? []).sorted()
    }

    func fakeRecording() throws -> URL {
        let url = root.appendingPathComponent("raw-\(UUID().uuidString).mp4")
        try Data("not-a-real-video".utf8).write(to: url)
        return url
    }

    static func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
struct CaptureOutputHandlerFixesTests {
    @Test func recordingWithAutoSaveToCustomFolderStillGoesToHistory() async throws {
        let h = try Harness(customSaveFolder: true)
        defer { h.cleanUp() }
        h.settings.autoSave = true

        await h.handler.handleRecording(try h.fakeRecording())

        #expect(h.history.entries.count == 1)
        #expect(h.history.entries.first?.kind == .video)
        if let entry = h.history.entries.first {
            #expect(FileManager.default.fileExists(atPath: h.history.url(for: entry).path))
        }
        #expect(h.savedFiles().count == 1)
        #expect(h.savedFiles().first?.hasSuffix(".mp4") == true)
    }

    @Test func gifFailureFallsBackToKeepingTheMP4() async throws {
        let h = try Harness(customSaveFolder: false)
        defer { h.cleanUp() }
        h.settings.recordingFormat = .gif

        await h.handler.handleRecording(try h.fakeRecording())

        #expect(h.quickAccess.shown.count == 1)
        let item = try #require(h.quickAccess.shown.first?.item)
        #expect(item.videoURL != nil)
        #expect(item.fileURL.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
        #expect(h.history.entries.first?.kind == .video)
        #expect(h.toast.messages.contains { $0.contains(String(localized: "Couldn’t create the GIF; the video was kept")) })
    }

    @Test func pressingSaveTwiceDoesNotCreateDuplicate() async throws {
        let h = try Harness(customSaveFolder: true)
        defer { h.cleanUp() }

        h.handler.handleScreenshot(Harness.makeImage())
        #expect(await waitUntil { !h.quickAccess.shown.isEmpty })
        let actions = try #require(h.quickAccess.shown.first?.actions)

        actions.onSave()
        #expect(h.savedFiles().count == 1)
        actions.onSave()
        #expect(h.savedFiles().count == 1)
        #expect(h.toast.messages.contains { $0.hasPrefix("Already in") })
    }

    @Test func screenshotWriteFailureStillCopiesToClipboard() async throws {
        let h = try Harness(customSaveFolder: false, brokenTemp: true)
        defer { h.cleanUp() }

        h.handler.handleScreenshot(Harness.makeImage())
        #expect(await waitUntil { h.toast.messages.contains(String(localized: "Couldn’t save the screenshot")) })

        #expect(h.clipboard.pngCopies.count == 1)
        #expect(h.clipboard.pngCopies.first?.fileURL == nil)
        #expect(h.clipboard.pngCopies.first?.data.isEmpty == false)
        #expect(h.quickAccess.shown.isEmpty)
        #expect(h.history.entries.isEmpty)
    }
}
