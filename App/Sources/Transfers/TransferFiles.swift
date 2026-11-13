import Foundation
import HexMobileCore

/// All cloud mutations use the existing security scope / NSFileCoordinator.
enum TransferFiles {
    struct Entry: Sendable {
        let manifest: TransferManifest
        let receipt: TransferReceipt?
        let directoryName: String
    }

    static func save(_ draft: TransferDraft, title: String, note: String,
                     status: TransferManifest.Status, in folder: URL) async throws {
        let manifest = TransferManifest(status: status, title: title, note: note, attachments: draft.attachments)
        let encoded = try TransferCodec.encode(manifest)
        try await SyncFolderIO.transfers(in: folder) { root in
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appending(path: manifest.id.uuidString, directoryHint: .isDirectory)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                for item in draft.attachments {
                    try fm.copyItem(at: draft.directory.appending(path: item.name), to: destination.appending(path: item.name))
                }
                // Commit marker last. A failed copy is never visible to the Mac.
                try encoded.write(to: destination.appending(path: TransferCodec.manifestFileName), options: .atomic)
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
        }
    }

    static func scan(in folder: URL) async throws -> [Entry] {
        try await SyncFolderIO.transfers(in: folder) { root in
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return [] }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var entries: [Entry] = []
            for directory in children {
                guard let id = UUID(uuidString: directory.lastPathComponent),
                      let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let manifestURL = directory.appending(path: TransferCodec.manifestFileName)
                try? fm.startDownloadingUbiquitousItem(at: manifestURL)
                guard let data = try? boundedData(at: manifestURL),
                      let manifest = try? TransferCodec.decodeManifest(from: data), manifest.id == id else { continue }
                let receiptURL = directory.appending(path: TransferCodec.receiptFileName)
                try? fm.startDownloadingUbiquitousItem(at: receiptURL)
                let receipt = (try? boundedData(at: receiptURL)).flatMap { try? TransferCodec.decodeReceipt(from: $0) }
                entries.append(Entry(manifest: manifest, receipt: receipt?.id == id ? receipt : nil,
                                     directoryName: directory.lastPathComponent))
            }
            return entries
        }
    }

    static func queue(id: UUID, directoryName: String, in folder: URL) async throws {
        try await SyncFolderIO.transfers(in: folder) { root in
            guard UUID(uuidString: directoryName) == id else { throw TransferImportError.unavailable }
            let url = root.appending(path: directoryName).appending(path: TransferCodec.manifestFileName)
            var manifest = try TransferCodec.decodeManifest(from: boundedData(at: url))
            guard manifest.id == id else { throw TransferImportError.unavailable }
            manifest.status = .queued
            try TransferCodec.encode(manifest).write(to: url, options: .atomic)
        }
    }

    static func remove(id: UUID, directoryName: String, in folder: URL) async throws {
        try await SyncFolderIO.transfers(in: folder) { root in
            guard UUID(uuidString: directoryName) == id else { throw TransferImportError.unavailable }
            let url = root.appending(path: directoryName)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= 64 * 1024 else {
            throw TransferImportError.unavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw TransferImportError.unavailable }
        return data
    }
}
