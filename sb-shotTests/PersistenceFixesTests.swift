import AppKit
import Carbon
@testable import SbShot
import Testing

private func makeTempDir(_ name: String = "dir") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sbshot-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: - FileStorage

@MainActor
struct FileStorageFixesTests {
    private func makeStorage() throws -> (FileStorage, URL, UserDefaults, String) {
        let temp = try makeTempDir("fs")
        let suite = "sbshot.tests.fs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (FileStorage(defaults: defaults, temporaryDirectory: temp), temp, defaults, suite)
    }

    @Test func sanitizedPrefixReplacesSeparatorsAndControlChars() {
        #expect(FileStorage.sanitizedPrefix("a/b:c") == "a-b-c")
        #expect(FileStorage.sanitizedPrefix("a\u{0}b\nc\td") == "a-b-c-d")
    }

    @Test func sanitizedPrefixTrimsAndRemovesLeadingDots() {
        #expect(FileStorage.sanitizedPrefix("  ..hidden  ") == "hidden")
        #expect(FileStorage.sanitizedPrefix("...") == "")
        #expect(FileStorage.sanitizedPrefix("") == "")
    }

    @Test func sanitizedPrefixCapsUTF8Length() {
        let long = String(repeating: "a", count: 400)
        #expect(FileStorage.sanitizedPrefix(long).utf8.count <= 150)
        // Caracteres multibyte: nunca se parte un caracter y se respeta el limite en bytes.
        let emoji = String(repeating: "😀", count: 100)
        let result = FileStorage.sanitizedPrefix(emoji)
        #expect(result.utf8.count <= 150)
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0 == "😀" })
    }

    @Test func fileNameHasNoSlashAndWritingSucceedsWithHostilePrefix() async throws {
        let (storage, temp, defaults, suite) = try makeStorage()
        defer {
            try? FileManager.default.removeItem(at: temp)
            defaults.removePersistentDomain(forName: suite)
        }
        let hostile = "../etc/pass:wd\n" + String(repeating: "x", count: 400)
        let name = storage.fileName(prefix: hostile, fileExtension: "png")
        #expect(!name.contains("/"))
        #expect(!name.hasPrefix("."))
        #expect(name.utf8.count < 255)

        let url = try await storage.writeTemporary(Data([1, 2, 3]), fileExtension: "png", prefix: hostile)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == temp.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emptyPrefixUsesOnlyDate() throws {
        let (storage, temp, defaults, suite) = try makeStorage()
        defer {
            try? FileManager.default.removeItem(at: temp)
            defaults.removePersistentDomain(forName: suite)
        }
        let name = storage.fileName(prefix: "///", fileExtension: "png")
        #expect(name.hasPrefix("---"))
        let blank = storage.fileName(prefix: "  ", fileExtension: "png")
        #expect(blank.hasSuffix(".png"))
        #expect(blank.first?.isNumber == true)
    }

    @Test func removesStaleFilesAndFoldersButKeepsRecentOnes() async throws {
        let (storage, temp, defaults, suite) = try makeStorage()
        let outside = try makeTempDir("outside")
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: outside)
            defaults.removePersistentDomain(forName: suite)
        }
        let fm = FileManager.default
        let oldDate = Date().addingTimeInterval(-3 * 24 * 3600)

        let oldFile = temp.appendingPathComponent("old.png")
        let newFile = temp.appendingPathComponent("new.png")
        let oldFolder = temp.appendingPathComponent("old-export", isDirectory: true)
        let newFolder = temp.appendingPathComponent("new-export", isDirectory: true)
        let outsideOld = outside.appendingPathComponent("outside.png")
        try Data([1]).write(to: oldFile)
        try Data([1]).write(to: newFile)
        try Data([1]).write(to: outsideOld)
        try fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data([1]).write(to: oldFolder.appendingPathComponent("inner.mp4"))
        try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for url in [oldFile, oldFolder, outsideOld] {
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }

        storage.removeStaleTemporaryFiles(olderThan: 24 * 3600)

        let removed = await waitUntil {
            !fm.fileExists(atPath: oldFile.path) && !fm.fileExists(atPath: oldFolder.path)
        }
        #expect(removed)
        #expect(fm.fileExists(atPath: newFile.path))
        #expect(fm.fileExists(atPath: newFolder.path))
        #expect(fm.fileExists(atPath: outsideOld.path))
    }
}

// MARK: - HistoryStore

@MainActor
struct HistoryStoreFixesTests {
    private func makeSource(_ ext: String = "png") throws -> (URL, URL) {
        let dir = try makeTempDir("src")
        let file = dir.appendingPathComponent("file.\(ext)")
        try Data([9, 9, 9]).write(to: file)
        return (dir, file)
    }

    @Test func corruptIndexIsBackedUpAndNotOverwrittenByAdd() throws {
        let dir = try makeTempDir("hist")
        let (srcDir, file) = try makeSource()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: srcDir)
        }
        let corrupt = Data("{ esto no es json".utf8)
        try corrupt.write(to: dir.appendingPathComponent("index.json"))

        let store = HistoryStore(directory: dir)
        #expect(store.entries.isEmpty)
        let backup = dir.appendingPathComponent("index.json.bak")
        #expect(try Data(contentsOf: backup) == corrupt)

        store.add(fileURL: file, kind: .image)
        #expect(store.entries.count == 1)
        // El respaldo sigue intacto y el nuevo indice es valido.
        #expect(try Data(contentsOf: backup) == corrupt)
        let reloaded = HistoryStore(directory: dir)
        #expect(reloaded.entries.count == 1)
    }

    @Test func toleratesMissingFieldsAndDropsBrokenEntries() throws {
        let dir = try makeTempDir("hist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        for name in ["a.mp4", "b.gif", "c.png"] {
            try Data([1]).write(to: dir.appendingPathComponent(name))
        }
        let json = """
        [
          {"fileName": "a.mp4"},
          {"id": "\(id.uuidString)", "fileName": "b.gif", "kind": "raro", "createdAt": "no-es-fecha"},
          {"kind": "image"},
          {"fileName": "c.png", "kind": "image", "createdAt": 1000}
        ]
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("index.json"))

        let store = HistoryStore(directory: dir)
        #expect(store.entries.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.fileName, $0) })
        #expect(byName["a.mp4"]?.kind == .video)
        #expect(byName["a.mp4"]?.createdAt == .distantPast)
        #expect(byName["b.gif"]?.kind == .gif)
        #expect(byName["b.gif"]?.id == id)
        #expect(byName["c.png"]?.kind == .image)
        // Nada se movio a respaldo: el indice era legible.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json.bak").path))
    }

    @Test func removesOrphanedFilesWhenIndexLoadsOK() throws {
        let dir = try makeTempDir("hist")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("kept.png"))
        try Data([1]).write(to: dir.appendingPathComponent("orphan.png"))
        try Data(#"[{"fileName":"kept.png"}]"#.utf8).write(to: dir.appendingPathComponent("index.json"))

        let store = HistoryStore(directory: dir)
        #expect(store.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kept.png").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan.png").path))
    }

    @Test func keepsOrphansWhenBackupFilesExist() throws {
        let dir = try makeTempDir("hist")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("kept.png"))
        try Data([1]).write(to: dir.appendingPathComponent("orphan.png"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("index.json.bak"))
        try Data(#"[{"fileName":"kept.png"}]"#.utf8).write(to: dir.appendingPathComponent("index.json"))

        _ = HistoryStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan.png").path))
    }

    @Test func keepsFilesWhenIndexIsCorrupt() throws {
        let dir = try makeTempDir("hist")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("precious.png"))
        try Data("basura".utf8).write(to: dir.appendingPathComponent("index.json"))

        _ = HistoryStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("precious.png").path))
    }
}

// MARK: - ToastController

@MainActor
struct ToastControllerFixesTests {
    @Test func showHideShowKeepsSecondToastVisible() async {
        let toast = ToastController()
        toast.show("Uno", systemImage: "checkmark")
        toast.hide()
        toast.show("Dos", systemImage: "checkmark")
        // Espera a que termine el fundido (0.2 s) del primer hide.
        try? await Task.sleep(nanoseconds: 700_000_000)
        #expect(toast.hasPanel)
        toast.hide()
        let gone = await waitUntil { !toast.hasPanel }
        #expect(gone)
    }
}

// MARK: - HotkeyManager

@MainActor
struct HotkeyManagerFixesTests {
    @Test func duplicateCombinationFailsAndIsNotStoredAsRegistered() {
        let manager = HotkeyManager()
        // Combinacion improbable de estar en uso por el sistema.
        let combo = GlobalShortcut(keyCode: 0x50, modifiers: [.command, .option, .control, .shift])
        manager.register([.captureArea: combo, .captureWindow: combo])

        #expect(manager.registered.count == 1)
        #expect(manager.failedActions.count == 1)
        let failed = manager.failedActions.first!
        #expect(manager.registered[failed] == nil)
        #expect(Set(manager.registered.keys).isDisjoint(with: manager.failedActions))

        // Al volver a registrar sin conflicto se limpian los fallos.
        manager.register([.captureArea: combo])
        #expect(manager.failedActions.isEmpty)
        #expect(manager.registered.keys.contains(.captureArea))
        manager.register([:])
        #expect(manager.registered.isEmpty)
    }
}
