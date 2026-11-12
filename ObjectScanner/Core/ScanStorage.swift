import Foundation
import Observation
import os

/// The directory tree for a single in-progress scan.
///
/// Every engine gets one of these and writes only inside it, so a failed or
/// cancelled scan is cleaned up by deleting one folder.
struct ScanWorkspace: Sendable {
    let id: UUID
    let root: URL

    /// Captured stills. Photogrammetry reads the whole directory.
    var imagesURL: URL { root.appending(path: "images", directoryHint: .isDirectory) }

    /// Reconstruction scratch space. Letting RealityKit checkpoint here means a
    /// backgrounded or crashed reconstruction can resume instead of restarting.
    var checkpointURL: URL { root.appending(path: "checkpoint", directoryHint: .isDirectory) }

    var modelURL: URL { root.appending(path: "model.usdz", directoryHint: .notDirectory) }
}

/// Owns the on-disk scan library.
@MainActor
@Observable
final class ScanStorage {
    private static let logger = Logger(subsystem: "com.example.ObjectScanner", category: "storage")

    private(set) var scans: [ScanRecord] = []

    private let fileManager = FileManager.default
    private let scansRoot: URL
    private let libraryFile: URL

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        scansRoot = documents.appending(path: "Scans", directoryHint: .isDirectory)
        libraryFile = scansRoot.appending(path: "library.json", directoryHint: .notDirectory)
        try? fileManager.createDirectory(at: scansRoot, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Library

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ScanRecord].self, from: data)
            // Drop records whose model file vanished — a stale row that opens to
            // nothing is worse than no row.
            scans = decoded.filter { fileManager.fileExists(atPath: modelURL(for: $0).path(percentEncoded: false)) }
            if scans.count != decoded.count { persist() }
        } catch {
            Self.logger.error("Kütüphane okunamadı: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(scans).write(to: libraryFile, options: .atomic)
        } catch {
            Self.logger.error("Kütüphane yazılamadı: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Workspaces

    func makeWorkspace() throws -> ScanWorkspace {
        let id = UUID()
        let workspace = ScanWorkspace(id: id, root: scansRoot.appending(path: id.uuidString, directoryHint: .isDirectory))
        try fileManager.createDirectory(at: workspace.imagesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace.checkpointURL, withIntermediateDirectories: true)
        return workspace
    }

    func discard(_ workspace: ScanWorkspace) {
        try? fileManager.removeItem(at: workspace.root)
    }

    /// Registers a finished scan. The model must already sit at `workspace.modelURL`.
    func commit(_ record: ScanRecord, workspace: ScanWorkspace) {
        precondition(record.id == workspace.id, "Record and workspace identifiers must match")
        scans.insert(record, at: 0)
        persist()
    }

    // MARK: - Records

    func directoryURL(for record: ScanRecord) -> URL {
        scansRoot.appending(path: record.id.uuidString, directoryHint: .isDirectory)
    }

    func modelURL(for record: ScanRecord) -> URL {
        directoryURL(for: record).appending(path: record.modelFileName, directoryHint: .notDirectory)
    }

    /// Replaces a stored record (same id) — used when a scan's calibration
    /// is recomputed or a caliper value is applied after the fact.
    func update(_ record: ScanRecord) {
        guard let index = scans.firstIndex(where: { $0.id == record.id }) else { return }
        scans[index] = record
        persist()
    }

    func rename(_ record: ScanRecord, to name: String) {
        guard let index = scans.firstIndex(of: record) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scans[index].name = trimmed
        persist()
    }

    func delete(_ record: ScanRecord) {
        try? fileManager.removeItem(at: directoryURL(for: record))
        scans.removeAll { $0.id == record.id }
        persist()
    }

    // MARK: - Space

    /// Source stills are kept after reconstruction on purpose: they let you
    /// re-run at a higher detail level without re-scanning the object. They are
    /// also by far the biggest thing on disk, hence this escape hatch.
    func intermediateBytes(for record: ScanRecord) -> Int64 {
        let directory = directoryURL(for: record)
        return [directory.appending(path: "images"), directory.appending(path: "checkpoint")]
            .reduce(0) { $0 + directorySize(at: $1) }
    }

    func purgeIntermediates(for record: ScanRecord) {
        let directory = directoryURL(for: record)
        try? fileManager.removeItem(at: directory.appending(path: "images"))
        try? fileManager.removeItem(at: directory.appending(path: "checkpoint"))
    }

    /// Checks for actual files, not just the folder. RoomPlan scans capture no
    /// stills at all, and an empty `images` directory would otherwise advertise a
    /// "process this on a Mac" path with nothing to process.
    func hasIntermediates(for record: ScanRecord) -> Bool {
        let images = directoryURL(for: record).appending(path: "images")
        let contents = try? fileManager.contentsOfDirectory(atPath: images.path(percentEncoded: false))
        return !(contents ?? []).isEmpty
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }
}
