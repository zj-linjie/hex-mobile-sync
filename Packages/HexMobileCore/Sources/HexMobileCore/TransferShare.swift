import Foundation

/// Builds the items for one system share sheet from a transfer directory.
///
/// Copies file attachments into `destination` and leaves `source` untouched,
/// including its manifest status. A missing, unfinished, or mismatched
/// attachment fails the whole call and leaves `destination` empty.
public enum TransferShare {
    public struct Prepared: Equatable, Sendable {
        public let text: String?
        public let files: [URL]
    }

    public enum Failure: Error, Equatable {
        case unavailable
    }

    /// `destination` must be an empty directory. Text is the note, the UTF-8
    /// body, or the note, a blank line, and the body. `body.txt` is not also
    /// copied as a file. Manifest and receipt are never copied.
    public static func prepare(source: URL, destination: URL) throws -> Prepared {
        do { return try make(source: source, destination: destination) }
        catch let error as Failure { throw error }
        catch { throw Failure.unavailable }
    }

    private static func make(source: URL, destination: URL) throws -> Prepared {
        let fm = FileManager.default
        guard try isDirectory(source), try isDirectory(destination),
              try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty
        else { throw Failure.unavailable }
        let manifest = try TransferCodec.decodeManifest(from: data(at: source.appending(path: TransferCodec.manifestFileName), limit: 64 * 1024))
        guard UUID(uuidString: source.lastPathComponent) == manifest.id else { throw Failure.unavailable }

        var body: String?
        var files: [(name: String, bytes: Int64)] = []
        for attachment in manifest.attachments {
            let url = source.appending(path: attachment.name)
            if attachment.kind == .text {
                guard attachment.name == TransferCodec.bodyFileName, body == nil else { throw Failure.unavailable }
                body = try readBody(at: url, expectedBytes: attachment.bytes)
            } else {
                try requireRegular(at: url, expectedBytes: attachment.bytes)
                files.append((attachment.name, attachment.bytes))
            }
        }
        let text = composedText(note: manifest.note, body: body)
        guard text != nil || !files.isEmpty else { throw Failure.unavailable }

        var copied: [URL] = []
        do {
            for file in files {
                let target = destination.appending(path: file.name)
                try fm.copyItem(at: source.appending(path: file.name), to: target)
                try requireRegular(at: target, expectedBytes: file.bytes)
                copied.append(target)
            }
        } catch {
            for url in copied { try? fm.removeItem(at: url) }
            throw Failure.unavailable
        }
        return Prepared(text: text, files: copied)
    }

    /// Note, then a blank line, then the body. An empty side is omitted.
    static func composedText(note: String, body: String?) -> String? {
        switch (note.isEmpty, body?.isEmpty ?? true) {
        case (true, true): nil
        case (true, false): body
        case (false, true): note
        case (false, false): note + "\n\n" + (body ?? "")
        }
    }

    private static func readBody(at url: URL, expectedBytes: Int64) throws -> String {
        let data = try data(at: url, limit: expectedBytes)
        guard Int64(data.count) == expectedBytes, let text = String(data: data, encoding: .utf8) else {
            throw Failure.unavailable
        }
        return text
    }

    private static func data(at url: URL, limit: Int64) throws -> Data {
        guard limit >= 0, limit <= TransferManifest.maximumAttachmentBytes else { throw Failure.unavailable }
        try requireRegular(at: url, expectedBytes: nil, maximumBytes: limit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(limit) + 1) ?? Data()
        guard data.count <= limit else { throw Failure.unavailable }
        return data
    }

    private static func requireRegular(at url: URL, expectedBytes: Int64) throws {
        try requireRegular(at: url, expectedBytes: expectedBytes, maximumBytes: expectedBytes)
    }

    private static func requireRegular(at url: URL, expectedBytes: Int64?, maximumBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        ])
        if let status = values.ubiquitousItemDownloadingStatus, status != .current && status != .downloaded {
            throw Failure.unavailable
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, Int64(size) <= maximumBytes,
              expectedBytes == nil || Int64(size) == expectedBytes
        else { throw Failure.unavailable }
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
