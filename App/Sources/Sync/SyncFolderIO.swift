import Foundation
import HexMobileCore

/// Coordinated file access to the sync folder picked in Files.
///
/// Every call brackets the work with security-scoped access to the folder and
/// uses `NSFileCoordinator`, so iCloud Drive (or any file provider) sees a
/// well-behaved client. All functions block and must run off the main actor;
/// the async wrappers do that with a detached task.
enum SyncFolderIO {
    enum IOError: LocalizedError {
        case accessDenied
        case coordination(String)
        /// `pending-vocabulary.json` exists but cannot be read or decoded
        /// (damaged, or written by a newer version). It is left untouched.
        case unreadablePendingVocabulary(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                String(localized: "Access to the sync folder was denied. Pick the folder again in Settings.")
            case let .coordination(message):
                String(localized: "The sync folder could not be read or written: \(message)")
            case let .unreadablePendingVocabulary(message):
                String(localized: "pending-vocabulary.json in the sync folder could not be read, so it was left unchanged: \(message)")
            }
        }
    }

    /// Reads a file in the folder. Returns `nil` when it does not exist.
    static func read(_ fileName: String, in folder: URL) async throws -> Data? {
        try await Task.detached(priority: .utility) {
            try withAccess(to: folder) {
                let url = folder.appending(path: fileName)
                // Ask the provider to materialize the file if it is only in the cloud.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                var coordinationError: NSError?
                var result: Result<Data?, any Error> = .success(nil)
                NSFileCoordinator(filePresenter: nil).coordinate(
                    readingItemAt: url,
                    options: [],
                    error: &coordinationError
                ) { readURL in
                    guard FileManager.default.fileExists(atPath: readURL.path(percentEncoded: false)) else {
                        result = .success(nil)
                        return
                    }
                    result = Result { try Data(contentsOf: readURL) }
                }
                if let coordinationError {
                    if coordinationError.domain == NSCocoaErrorDomain,
                       coordinationError.code == NSFileReadNoSuchFileError {
                        return nil
                    }
                    throw IOError.coordination(coordinationError.localizedDescription)
                }
                return try result.get()
            }
        }.value
    }

    /// Replaces a file in the folder with `data`.
    static func write(_ data: Data, to fileName: String, in folder: URL) async throws {
        try await Task.detached(priority: .utility) {
            try withAccess(to: folder) {
                try coordinatedWrite(at: folder.appending(path: fileName), options: [.forReplacing]) { url in
                    try data.write(to: url, options: [.atomic])
                }
            }
        }.value
    }

    /// Read-modify-write of `pending-vocabulary.json` under one coordinated
    /// write, so a concurrent Mac update is never lost.
    /// - Parameter update: receives the current file content (empty when the
    ///   file is missing) and returns the new content, or `nil` to leave the
    ///   file untouched.
    /// - Throws: ``IOError/unreadablePendingVocabulary(_:)`` when the file
    ///   exists but cannot be read or decoded; it is never overwritten then,
    ///   so entries the Mac has not applied yet are not lost.
    static func updatePendingVocabulary(
        in folder: URL,
        _ update: @escaping @Sendable (PendingVocabulary) -> PendingVocabulary?
    ) async throws {
        try await Task.detached(priority: .utility) {
            try withAccess(to: folder) {
                let url = folder.appending(path: SyncCodec.pendingVocabularyFileName)
                try coordinatedWrite(at: url, options: [.forMerging]) { url in
                    var current = PendingVocabulary()
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        do {
                            let data = try Data(contentsOf: url)
                            current = try SyncCodec.decodePendingVocabulary(from: data)
                        } catch {
                            throw IOError.unreadablePendingVocabulary(error.localizedDescription)
                        }
                    }
                    guard let next = update(current), next != current else { return }
                    try SyncCodec.encode(next).write(to: url, options: [.atomic])
                }
            }
        }.value
    }

    /// Deletes a file in the folder. A missing file is not an error.
    static func remove(_ fileName: String, in folder: URL) async throws {
        try await Task.detached(priority: .utility) {
            try withAccess(to: folder) {
                let url = folder.appending(path: fileName)
                try coordinatedWrite(at: url, options: [.forDeleting]) { url in
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        return
                    }
                }
            }
        }.value
    }

    /// The transfer tree shares the same security scope and coordinator as
    /// vocabulary sync. Coordinate its parent so create/queue/delete are atomic
    /// with respect to file-provider readers and other phone clients.
    static func transfers<T: Sendable>(
        in folder: URL, _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .utility) {
            try withAccess(to: folder) {
                var result: T?
                try coordinatedWrite(at: folder, options: [.forMerging]) { url in
                    result = try body(url.appending(path: TransferCodec.directoryName, directoryHint: .isDirectory))
                }
                return result!
            }
        }.value
    }

    // MARK: - Helpers

    private static func withAccess<T>(to folder: URL, _ body: () throws -> T) throws -> T {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: folder.path(percentEncoded: false)) || didStart else {
            throw IOError.accessDenied
        }
        return try body()
    }

    private static func coordinatedWrite(
        at url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: options,
            error: &coordinationError
        ) { writeURL in
            do { try body(writeURL) } catch { bodyError = error }
        }
        if let coordinationError { throw IOError.coordination(coordinationError.localizedDescription) }
        if let bodyError { throw bodyError }
    }
}
