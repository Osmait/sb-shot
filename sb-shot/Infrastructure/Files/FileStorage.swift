import AppKit
import UniformTypeIdentifiers

/// Temporary files, save folder (with a sandbox bookmark) and image encoding.
final class FileStorage {
    let temporaryDirectory: URL

    /// Called when the custom folder is no longer available and the default one is used again.
    var onSaveFolderUnavailable: (() -> Void)?

    private let defaults: UserDefaults
    private let bookmarkKey = "sbshot.saveFolderBookmark"
    private var resolvedFolder: URL?

    init(defaults: UserDefaults = .standard, temporaryDirectory: URL? = nil) {
        self.defaults = defaults
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("sb-shot", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Names

    func fileName(prefix: String, fileExtension: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let cleanPrefix = Self.sanitizedPrefix(prefix)
        let base = cleanPrefix.isEmpty ? formatter.string(from: date) : "\(cleanPrefix) \(formatter.string(from: date))"
        return "\(base).\(fileExtension)"
    }

    func temporaryURL(prefix: String, fileExtension: String, date: Date = Date()) -> URL {
        uniqueURL(in: temporaryDirectory, fileName: fileName(prefix: prefix, fileExtension: fileExtension, date: date))
    }

    /// Removes path separators and control characters, and limits the length so the full name
    /// (date, counter and extension included) stays below 255 bytes.
    static func sanitizedPrefix(_ prefix: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        var clean = String(String.UnicodeScalarView(prefix.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        // No leading dot, to avoid creating hidden files.
        while clean.hasPrefix(".") {
            clean.removeFirst()
        }
        while clean.utf8.count > maxPrefixBytes {
            clean.removeLast()
        }
        return clean.trimmingCharacters(in: .whitespaces)
    }

    private static let maxPrefixBytes = 150

    /// Copies a file to the temporary folder (so it doesn't depend on files that may be deleted).
    func temporaryCopy(of file: URL, prefix: String, date: Date = Date()) throws -> URL {
        let destination = temporaryURL(prefix: prefix, fileExtension: file.pathExtension, date: date)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Deletes temporary files older than `age` seconds. Called at launch, when no file in the
    /// folder is in use (saved copies and the history live elsewhere).
    func removeStaleTemporaryFiles(olderThan age: TimeInterval = 24 * 60 * 60) {
        let directory = temporaryDirectory
        Task.detached(priority: .utility) {
            Self.removeFiles(in: directory, olderThan: Date().addingTimeInterval(-age))
        }
    }

    private nonisolated static func removeFiles(in directory: URL, olderThan limit: Date) {
        // Subfolders too (video editor exports), with all their contents.
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for url in contents {
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true || values.isDirectory == true,
                let modified = values.contentModificationDate,
                modified < limit
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Images

    func encode(_ image: NSImage, as format: ImageFileFormat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Self.encode(cgImage, pointSize: image.size, as: Self.fileType(for: format))
    }

    /// Encodes off the main thread.
    func encodeInBackground(_ image: NSImage, as format: ImageFileFormat) async -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = image.size
        let fileType = Self.fileType(for: format)
        return await Task.detached(priority: .userInitiated) {
            Self.encode(cgImage, pointSize: size, as: fileType)
        }.value
    }

    func writeTemporary(_ image: NSImage, format: ImageFileFormat, prefix: String) throws -> URL {
        guard let data = encode(image, as: format) else { throw CocoaError(.fileWriteUnknown) }
        let url = temporaryURL(prefix: prefix, fileExtension: format.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes already encoded data to the temporary folder, off the main thread.
    func writeTemporary(_ data: Data, fileExtension: String, prefix: String) async throws -> URL {
        let url = temporaryURL(prefix: prefix, fileExtension: fileExtension)
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url, options: .atomic)
        }.value
        return url
    }

    private nonisolated static func encode(_ cgImage: CGImage, pointSize: CGSize, as fileType: NSBitmapImageRep.FileType) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // Keep the size in points so Retina screenshots open at the right size.
        bitmap.size = pointSize
        let properties: [NSBitmapImageRep.PropertyKey: Any] = fileType == .jpeg ? [.compressionFactor: 0.9] : [:]
        return bitmap.representation(using: fileType, properties: properties)
    }

    private static func fileType(for format: ImageFileFormat) -> NSBitmapImageRep.FileType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        }
    }

    // MARK: - Save folder

    var defaultSaveFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("sb-shot", isDirectory: true)
    }

    var saveFolder: URL {
        resolvedSaveFolder() ?? defaultSaveFolder
    }

    var hasCustomSaveFolder: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    var saveFolderDisplayPath: String {
        (saveFolder.path as NSString).abbreviatingWithTildeInPath
    }

    @discardableResult
    func chooseSaveFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder where screenshots and recordings will be saved.")

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        defaults.set(bookmark, forKey: bookmarkKey)
        resolvedFolder = nil
        return true
    }

    func resetSaveFolder() {
        defaults.removeObject(forKey: bookmarkKey)
        resolvedFolder = nil
    }

    /// Opens the save folder in Finder, creating it if it doesn't exist yet.
    func openSaveFolder() {
        let folder = saveFolder
        let isScoped = folder.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Copies the file to the save folder and returns its new location.
    func saveToFolder(_ file: URL, fileName: String? = nil) throws -> URL {
        let folder = saveFolder
        let isScoped = folder.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(in: folder, fileName: fileName ?? file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Whether the file is directly inside the current save folder.
    func isInSaveFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == saveFolder.standardizedFileURL.path
    }

    /// Asks for a location with the save panel and copies the file there.
    /// Returns `nil` if the user cancels and throws if the copy fails.
    func saveWithPanel(_ file: URL, suggestedName: String? = nil) throws -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName ?? file.lastPathComponent
        if let type = UTType(filenameExtension: file.pathExtension) {
            panel.allowedContentTypes = [type]
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            try manager.copyItem(at: file, to: url)
            return url
        }

        // Replace without deleting the destination first: if something fails, the original file stays intact.
        let staging = uniqueURL(in: temporaryDirectory, fileName: "replacement-\(UUID().uuidString).\(file.pathExtension)")
        try manager.copyItem(at: file, to: staging)
        do {
            _ = try manager.replaceItemAt(url, withItemAt: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return url
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Private

    /// Resolves the bookmark only once. If it can no longer be resolved, it is deleted so Settings
    /// shows the default folder that is actually used.
    private func resolvedSaveFolder() -> URL? {
        if let resolvedFolder {
            return resolvedFolder
        }
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            defaults.removeObject(forKey: bookmarkKey)
            onSaveFolderUnavailable?()
            return nil
        }

        if isStale {
            let isScoped = url.startAccessingSecurityScopedResource()
            if let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(refreshed, forKey: bookmarkKey)
            }
            if isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        resolvedFolder = url
        return url
    }

    private func uniqueURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
