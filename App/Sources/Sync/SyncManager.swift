import Foundation
import HexMobileCore
import Observation

/// Keeps the synced Hex bundle and the iPhone's pending vocabulary.
///
/// The user picks the "Hex Mobile" folder once in Files; the app stores a
/// bookmark to it (no iCloud entitlement needed) and reads
/// `hex-mobile-sync.json`, writes `pending-vocabulary.json` and, when enabled,
/// `iphone-history.jsonl`. The last good bundle is cached on device so text
/// rules keep working offline.
@MainActor
@Observable
final class SyncManager {
    /// Outcome of the last sync attempt, for Settings.
    enum Status: Equatable {
        case notConfigured
        case never
        case syncing
        case succeeded(Date)
        case failed(String)
    }

    private static let bookmarkKey = "sync.folderBookmark"
    private static let lastSyncKey = "sync.lastSuccess"

    /// The synced bundle (last good copy), if any.
    private(set) var bundle: SyncBundle?
    /// Terms added on iPhone that the Mac has not applied yet.
    private(set) var pending = PendingVocabulary()
    /// The picked folder, resolved from the bookmark.
    private(set) var folderURL: URL?
    private(set) var status: Status = .notConfigured
    /// A non-fatal problem worth showing (e.g. pending file not writable).
    private(set) var warning: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundle = Self.loadCachedBundle()
        pending = Self.loadLocalPending()
        folderURL = resolveBookmark()
        if folderURL == nil {
            status = .notConfigured
        } else if let last = defaults.object(forKey: Self.lastSyncKey) as? Date {
            status = .succeeded(last)
        } else {
            status = .never
        }
    }

    /// Display name of the picked folder.
    var folderName: String? { folderURL?.lastPathComponent }

    /// Synced vocabulary (empty before the first sync).
    var syncedVocabulary: [VocabularyEntry] { bundle?.vocabulary ?? [] }

    /// Names of the synced modes the user can pick as an override.
    var modeNames: [String] { bundle?.modes.map(\.name) ?? [] }

    /// Explicitly curated corrections bundled for this personal installation.
    private static let localCorrections: [ContextualCorrection] = {
        guard let url = Bundle.main.url(forResource: "LocalCorrections", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ContextualCorrection].self, from: data)) ?? []
    }()

    var localCorrectionCount: Int { Self.localCorrections.count }

    /// Builds the text processor for the current bundle, override and pending terms.
    func textProcessor(modeOverride: String?) -> TextProcessor {
        if let bundle {
            return TextProcessor(bundle: bundle, modeOverride: modeOverride, pendingVocabulary: pending.entries, contextualCorrections: Self.localCorrections)
        }
        return TextProcessor(vocabulary: pending.entries.map(\.vocabularyEntry), contextualCorrections: Self.localCorrections)
    }

    /// Recognizer bias terms.
    var contextualStrings: [String] {
        ContextualVocabulary.terms(vocabulary: syncedVocabulary, pending: pending.entries)
    }

    /// Set while the recognizers (Apple's and Whisper's prompt) get no terms.
    var vocabularyNotice: VocabularyNotice? {
        VocabularyNotice.make(termCount: contextualStrings.count, folderPicked: folderURL != nil)
    }

    // MARK: - Folder

    /// Stores the folder picked with `fileImporter` and syncs.
    func setFolder(_ url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            folderURL = url
            warning = nil
            status = .never
        } catch {
            status = .failed(String(localized: "The folder could not be saved: \(error.localizedDescription)"))
            return
        }
        await refresh()
    }

    /// Forgets the folder. Removes `iphone-history.jsonl` from it first, so
    /// no dictation text stays behind in a folder the app no longer manages.
    /// The cached bundle and pending terms stay on device.
    func forgetFolder() async {
        await removeHistoryExport()
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
        folderURL = nil
        status = .notConfigured
        warning = nil
    }

    // MARK: - Sync

    /// Reads the bundle, reconciles pending terms and writes them back.
    /// Concurrent calls join the one in flight.
    func refresh(historyExport: Data? = nil) async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh(historyExport: historyExport) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(historyExport: Data?) async {
        guard let folder = folderURL ?? resolveBookmark() else {
            status = .notConfigured
            return
        }
        folderURL = folder
        status = .syncing
        warning = nil
        do {
            if let data = try await SyncFolderIO.read(SyncCodec.bundleFileName, in: folder) {
                let decoded = try SyncCodec.decodeBundle(from: data)
                bundle = decoded
                Self.saveCachedBundle(data)
                let reconciled = pending.removingApplied(in: decoded.vocabulary)
                if reconciled != pending {
                    pending = reconciled
                    saveLocalPending()
                }
            } else {
                warning = String(localized: "No hex-mobile-sync.json in this folder yet. Run the Mac sync script, then refresh.")
            }
            do {
                try await pushPending(to: folder)
            } catch let error as SyncFolderIO.IOError {
                // A damaged or newer pending file is left alone (and reported);
                // the rest of the sync still runs.
                guard case .unreadablePendingVocabulary = error else { throw error }
                warning = error.localizedDescription
            }
            if let historyExport {
                try await SyncFolderIO.write(historyExport, to: SyncCodec.historyExportFileName, in: folder)
            }
            let now = Date()
            defaults.set(now, forKey: Self.lastSyncKey)
            status = .succeeded(now)
        } catch let error as SyncCodecError {
            status = .failed(error.description)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Writes only the history export (used after each dictation when sharing is on).
    func exportHistory(_ data: Data) async {
        guard let folder = folderURL else { return }
        do {
            try await SyncFolderIO.write(data, to: SyncCodec.historyExportFileName, in: folder)
        } catch {
            warning = error.localizedDescription
        }
    }

    /// Deletes `iphone-history.jsonl` from the folder (sharing turned off,
    /// history deleted, or folder forgotten). A missing file is fine.
    func removeHistoryExport() async {
        guard let folder = folderURL ?? resolveBookmark() else { return }
        do {
            try await SyncFolderIO.remove(SyncCodec.historyExportFileName, in: folder)
        } catch {
            warning = error.localizedDescription
        }
    }

    // MARK: - Pending vocabulary

    /// Adds a term for the Mac to apply. Returns the outcome for UI feedback.
    @discardableResult
    func addPendingTerm(_ term: String, soundsLike: [String]) async -> PendingVocabulary.AddOutcome {
        let outcome = pending.add(term: term, soundsLike: soundsLike)
        switch outcome {
        case .added, .merged: break
        case .unchanged, .rejectedBlankTerm: return outcome
        }
        saveLocalPending()
        if let folder = folderURL {
            do { try await pushPending(to: folder) } catch { warning = error.localizedDescription }
        }
        return outcome
    }

    /// Removes a pending term from the device and from the sync folder.
    func removePendingTerm(id: UUID) async {
        guard let removed = pending.remove(id: id) else { return }
        saveLocalPending()
        guard let folder = folderURL else { return }
        let key = removed.termKey
        do {
            try await SyncFolderIO.updatePendingVocabulary(in: folder) { file in
                var file = file
                if let match = file.entries.first(where: { $0.termKey == key }) {
                    _ = file.remove(id: match.id)
                    return file
                }
                return nil
            }
        } catch {
            warning = error.localizedDescription
        }
    }

    /// Merges local pending terms into the folder's file (never drops the
    /// Mac's view of it; applied entries are removed by the Mac).
    private func pushPending(to folder: URL) async throws {
        let local = pending
        guard !local.isEmpty else { return }
        try await SyncFolderIO.updatePendingVocabulary(in: folder) { file in
            file.merging(local)
        }
    }

    // MARK: - Persistence

    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isStale {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.bookmarkKey)
            }
        }
        return url
    }

    private static func loadCachedBundle() -> SyncBundle? {
        guard let data = try? Data(contentsOf: AppPaths.cachedBundleFile) else { return nil }
        return try? SyncCodec.decodeBundle(from: data)
    }

    private static func saveCachedBundle(_ data: Data) {
        try? data.write(to: AppPaths.cachedBundleFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func loadLocalPending() -> PendingVocabulary {
        guard let data = try? Data(contentsOf: AppPaths.pendingVocabularyFile),
              let pending = try? SyncCodec.decodePendingVocabulary(from: data)
        else { return PendingVocabulary() }
        return pending
    }

    private func saveLocalPending() {
        guard let data = try? SyncCodec.encode(pending) else { return }
        try? data.write(to: AppPaths.pendingVocabularyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    #if DEBUG
    /// Synthetic content for screenshots (`-HexMobileDemo YES`). Never persisted.
    func loadDemoContent(bundle: SyncBundle, pending: PendingVocabulary) {
        self.bundle = bundle
        self.pending = pending
        status = .succeeded(Date())
    }
    #endif
}
