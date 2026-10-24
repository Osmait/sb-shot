import AppKit
import Combine

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case image
        case video
        case gif
    }

    let id: UUID
    let fileName: String
    let kind: Kind
    let createdAt: Date

    init(id: UUID, fileName: String, kind: Kind, createdAt: Date) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.createdAt = createdAt
    }

    /// Only `fileName` is required; the rest is inferred if missing or unrecognized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decode(String.self, forKey: .fileName)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? Self.kind(forExtension: (fileName as NSString).pathExtension)
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? .distantPast
    }

    private static func kind(forExtension ext: String) -> Kind {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v": .video
        case "gif": .gif
        default: .image
        }
    }
}

/// Decodes each entry separately so a corrupted entry doesn't invalidate the whole index.
private struct LossyHistoryEntry: Decodable {
    let entry: HistoryEntry?

    init(from decoder: Decoder) throws {
        entry = try? HistoryEntry(from: decoder)
    }
}

/// Keeps a copy of every screenshot and recording in Application Support for the history.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    let directory: URL
    private let indexURL: URL
    private let limit: Int
    /// False if the index could neither be read nor backed up: it isn't overwritten so entries aren't lost.
    private var canPersist = true

    init(limit: Int = 100, directory: URL? = nil) {
        self.limit = limit
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appendingPathComponent("sb-shot/History", isDirectory: true)
        indexURL = self.directory.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        load()
    }

    func add(fileURL: URL, kind: HistoryEntry.Kind) {
        let id = UUID()
        let fileName = "\(id.uuidString).\(fileURL.pathExtension)"
        let destination = directory.appendingPathComponent(fileName)

        do {
            try FileManager.default.copyItem(at: fileURL, to: destination)
        } catch {
            return
        }

        entries.insert(HistoryEntry(id: id, fileName: fileName, kind: kind, createdAt: Date()), at: 0)
        trim()
        persist()
    }

    func url(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent(entry.fileName)
    }

    func remove(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: url(for: entry))
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        for entry in entries {
            try? FileManager.default.removeItem(at: url(for: entry))
        }
        entries.removeAll()
        persist()
    }

    private func trim() {
        guard entries.count > limit else { return }
        for entry in entries[limit...] {
            try? FileManager.default.removeItem(at: url(for: entry))
        }
        entries = Array(entries.prefix(limit))
    }

    private func load() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: indexURL.path) else { return }

        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([LossyHistoryEntry].self, from: data).compactMap(\.entry)
            entries = decoded.filter { manager.fileExists(atPath: url(for: $0).path) }
            removeOrphanedFiles()
        } catch {
            backUpIndex()
        }
    }

    /// Saves the unreadable index as `.bak` before the next `persist()` overwrites it.
    private func backUpIndex() {
        var backup = directory.appendingPathComponent("index.json.bak")
        if FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("index-\(Int(Date().timeIntervalSince1970)).json.bak")
        }
        do {
            try FileManager.default.moveItem(at: indexURL, to: backup)
        } catch {
            canPersist = false
        }
    }

    /// Deletes files that no index references. Skipped if there are backups, because their
    /// files are only referenced there.
    private func removeOrphanedFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles), !contents.contains(where: { $0.pathExtension == "bak" }) else { return }

        let referenced = Set(entries.map(\.fileName))
        for url in contents where url.lastPathComponent != indexURL.lastPathComponent && !referenced.contains(url.lastPathComponent) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist() {
        guard canPersist, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
