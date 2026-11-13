import Foundation
import HexMobileCore
import UniformTypeIdentifiers

/// Temporary file copies live only for this presentation/import. No cloud
/// directory exists until the user chooses an action and a folder.
struct TransferDraft: Sendable {
    let directory: URL
    let attachments: [TransferAttachment]
    let suggestedTitle: String

    func discard() { try? FileManager.default.removeItem(at: directory) }
}

enum TransferImportError: LocalizedError {
    case unsupported, folders, count, size, duplicate, unavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Share plain text, a URL, an image, or a regular file. Rich text needs a plain-text representation.")
        case .folders: String(localized: "Folders and packages cannot be transferred.")
        case .count: String(localized: "A transfer can contain up to 10 attachments. Nothing was saved.")
        case .size: String(localized: "Each attachment must be at most 100 MB, and the transfer at most 200 MB. Nothing was saved.")
        case .duplicate: String(localized: "Some filenames are duplicated or reserved. Rename the files and share again. Nothing was saved.")
        case .unavailable: String(localized: "The shared item could not be read. Download it in the source app and try again.")
        }
    }
}

/// File-to-file staging, shared by the app's document handoff and extension.
/// Never logs content, filenames or provider errors that may contain payloads.
enum TransferStaging {
    static func newDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hex-transfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }

    static func copy(_ source: URL, name: String, uti: String, kind: TransferAttachment.Kind,
                     into directory: URL) throws -> TransferAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isDirectory != true, values.isPackage != true else { throw TransferImportError.folders }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TransferImportError.unsupported }
        guard TransferAttachment.isSafeName(name), (kind == .text || name.lowercased() != "body.txt") else {
            throw TransferImportError.duplicate
        }
        let destination = directory.appending(path: name)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard !names.contains(where: { $0.lowercased() == name.lowercased() }) else { throw TransferImportError.duplicate }
        guard Int64(values.fileSize ?? 0) <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
        // Bounded streaming also enforces limits if a source grows while copied.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            bytes += Int64(chunk.count)
            guard bytes <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
            try output.write(contentsOf: chunk)
        }
        return TransferAttachment(name: name, uti: uti, bytes: bytes, kind: kind)
    }

    static func document(_ url: URL) throws -> TransferDraft {
        let directory = try newDirectory()
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? .data
            if type.conforms(to: .text), !type.conforms(to: .plainText) { throw TransferImportError.unsupported }
            let isText = type.conforms(to: .plainText)
            let item = try copy(url, name: isText ? "body.txt" : url.lastPathComponent,
                                uti: isText ? UTType.utf8PlainText.identifier : type.identifier,
                                kind: isText ? .text : type.conforms(to: .image) ? .image : .file, into: directory)
            if isText { try normalizeText(at: directory.appending(path: item.name)) }
            let bytes = try directory.appending(path: item.name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(bytes) <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
            return TransferDraft(directory: directory, attachments: [.init(name: item.name, uti: item.uti, bytes: Int64(bytes), kind: item.kind)],
                                 suggestedTitle: url.deletingPathExtension().lastPathComponent)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// Validate UTF-8 incrementally (including sequences split at a chunk edge).
    /// UTF-16 with a BOM is converted in bounded chunks; output is UTF-8.
    /// Never silently forward rich-text bytes as a text body.
    static func normalizeText(at url: URL) throws {
        try convertUTF16IfNeeded(at: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remainder = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            remainder.append(chunk)
            var cut = remainder.count
            if let last = remainder.last, last >= 0x80 {
                var start = remainder.count - 1
                while start > 0, remainder[start] & 0xC0 == 0x80 { start -= 1 }
                let lead = remainder[start]
                let needed = lead & 0xE0 == 0xC0 ? 2 : lead & 0xF0 == 0xE0 ? 3 : lead & 0xF8 == 0xF0 ? 4 : 1
                if remainder.count - start < needed { cut = start }
            }
            guard String(data: remainder.prefix(cut), encoding: .utf8) != nil else { throw TransferImportError.unsupported }
            remainder = Data(remainder.dropFirst(cut))
        }
        guard remainder.isEmpty else { throw TransferImportError.unsupported }
    }

    private static func convertUTF16IfNeeded(at url: URL) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let bom = try input.read(upToCount: 2) ?? Data()
        let encoding: String.Encoding
        if bom == Data([0xFF, 0xFE]) { encoding = .utf16LittleEndian }
        else if bom == Data([0xFE, 0xFF]) { encoding = .utf16BigEndian }
        else { return }
        let temp = url.deletingLastPathComponent().appending(path: ".utf8-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var pending = Data()
        var bytes: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var cut = pending.count - pending.count % 2
            if cut >= 2 {
                let a = UInt16(pending[cut - 2]), b = UInt16(pending[cut - 1])
                let last = encoding == .utf16LittleEndian ? a | (b << 8) : (a << 8) | b
                if (0xD800...0xDBFF).contains(last) { cut -= 2 }
            }
            guard let text = String(data: pending.prefix(cut), encoding: encoding) else { throw TransferImportError.unsupported }
            let utf8 = Data(text.utf8)
            bytes += Int64(utf8.count)
            guard bytes <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
            try output.write(contentsOf: utf8)
            pending = Data(pending.dropFirst(cut))
        }
        guard pending.isEmpty else { throw TransferImportError.unsupported }
        try output.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
