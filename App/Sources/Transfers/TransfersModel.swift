import Foundation
import HexMobileCore
import Observation

@MainActor
@Observable
final class TransfersModel {
    struct Row: Codable, Identifiable, Sendable {
        enum Status: String, Codable, Sendable { case held, queued, delivered }
        let id: UUID
        let title: String
        let createdAt: Date
        let kind: TransferAttachment.Kind
        let count: Int
        var status: Status
        let directoryName: String
    }

    private(set) var rows: [Row] = []
    private(set) var isBusy = false
    var errorMessage: String?
    var needsFolder = false
    var openedDocument = false
    var shareItem: ShareItem?
    private var shareDirectory: URL?
    private var incoming: TransferDraft?
    private var delivered: [Row] = []
    private let sync: SyncManager
    private let summariesURL: URL

    init(sync: SyncManager) {
        self.sync = sync
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        summariesURL = base.appending(path: "delivered-transfers.json")
        if let data = try? Data(contentsOf: summariesURL),
           let saved = try? JSONDecoder().decode([Row].self, from: data) {
            delivered = saved.filter { $0.status == .delivered }
        }
        rows = delivered
    }

    func refresh() async {
        guard !isBusy, incoming == nil else { return }
        guard let folder = sync.folderURL else { rows = delivered; return }
        isBusy = true
        defer { isBusy = false }
        do { try await reload(in: folder); errorMessage = nil }
        catch { errorMessage = String(localized: "Transfers could not be refreshed. Check the sync folder and try again.") }
    }

    private func reload(in folder: URL) async throws {
        let entries = try await TransferFiles.scan(in: folder)
        var next = delivered
        for entry in entries where entry.receipt != nil {
            if !next.contains(where: { $0.id == entry.manifest.id }) { next.append(row(entry, status: .delivered)) }
        }
        // Persist metadata first. A write failure must leave all cloud payloads.
        try await persist(next)
        delivered = next
        let deliveredIDs = Set(delivered.map(\.id))
        rows = (delivered + entries.filter { $0.receipt == nil && !deliveredIDs.contains($0.manifest.id) }.map {
            row($0, status: $0.manifest.status == .held ? .held : .queued)
        }).sorted { $0.createdAt > $1.createdAt }
        for entry in entries where entry.receipt != nil {
            try await TransferFiles.remove(id: entry.manifest.id, directoryName: entry.directoryName, in: folder)
        }
    }

    private func row(_ entry: TransferFiles.Entry, status: Row.Status) -> Row {
        Row(id: entry.manifest.id, title: entry.manifest.title, createdAt: entry.manifest.createdAt,
            kind: entry.manifest.attachments.first?.kind ?? .file, count: entry.manifest.attachments.count,
            status: status, directoryName: entry.directoryName)
    }

    func queue(_ row: Row) async {
        guard !isBusy, row.status == .held, let folder = sync.folderURL else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await TransferFiles.queue(id: row.id, directoryName: row.directoryName, in: folder)
            try await reload(in: folder)
        } catch { errorMessage = String(localized: "The transfer could not be queued. Check the sync folder and try again.") }
    }

    func share(_ row: Row) async {
        guard !isBusy, shareItem == nil, row.status != .delivered, let folder = sync.folderURL else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let copy = try await TransferFiles.shareCopy(id: row.id, directoryName: row.directoryName, in: folder)
            var items: [Any] = []
            if let text = copy.text { items.append(text) }
            items.append(contentsOf: copy.files)
            shareDirectory = copy.directory
            shareItem = ShareItem(items: items)
        } catch {
            errorMessage = String(localized: "This transfer could not be shared. Download it in the sync folder and try again.")
        }
    }

    /// Removes the temporary copies after the system share sheet closes.
    func cleanupShare() {
        shareItem = nil
        if let shareDirectory {
            try? FileManager.default.removeItem(at: shareDirectory)
            self.shareDirectory = nil
        }
    }

    func delete(_ row: Row) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if row.status == .delivered {
                let next = delivered.filter { $0.id != row.id }
                try await persist(next)
                delivered = next
            } else {
                guard let folder = sync.folderURL else { throw TransferImportError.unavailable }
                try await TransferFiles.remove(id: row.id, directoryName: row.directoryName, in: folder)
            }
            rows.removeAll { $0.id == row.id }
        } catch { errorMessage = String(localized: "The transfer could not be deleted. Check the sync folder and try again.") }
    }

    /// Document handoff is always held. No content is queued by opening a URL.
    func openDocument(_ url: URL) async {
        guard !isBusy, incoming == nil else { return }
        isBusy = true
        do {
            openedDocument = true
            incoming = try await Task.detached(priority: .userInitiated) { try TransferStaging.document(url) }.value
            isBusy = false
            if sync.folderURL == nil { needsFolder = true }
            else { await saveIncoming() }
        } catch {
            isBusy = false
            errorMessage = (error as? TransferImportError)?.errorDescription ?? String(localized: "The shared item could not be read. Download it in the source app and try again.")
        }
    }

    func pickedFolder(_ url: URL) async {
        await sync.setFolder(url)
        await saveIncoming()
    }

    func cancelIncoming() {
        incoming?.discard()
        incoming = nil
        needsFolder = false
    }

    private func saveIncoming() async {
        guard let incoming, let folder = sync.folderURL, !isBusy else { cancelIncoming(); return }
        isBusy = true
        defer { isBusy = false; cancelIncoming() }
        do {
            let title = incoming.suggestedTitle.components(separatedBy: .newlines).joined(separator: " ")
            try await TransferFiles.save(incoming, title: title.isEmpty ? String(localized: "Transfer") : title, note: "", status: .held, in: folder)
            try await reload(in: folder)
        } catch { errorMessage = String(localized: "The transfer could not be saved. Check the sync folder and try again.") }
    }

    struct ShareItem: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    private func persist(_ rows: [Row]) async throws {
        let url = summariesURL
        let data = try JSONEncoder().encode(rows)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }
}
