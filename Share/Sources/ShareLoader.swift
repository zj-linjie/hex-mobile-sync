import Foundation
import HexMobileCore
import UniformTypeIdentifiers
import UIKit

@MainActor
enum ShareLoader {
    /// Providers are consumed once, in order, while their callback owns each
    /// temporary URL. The callback copies bytes before returning that URL.
    static func load(_ providers: [NSItemProvider]) async throws -> TransferDraft {
        guard !providers.isEmpty else { throw TransferImportError.unsupported }
        guard providers.count <= TransferManifest.maximumAttachments else { throw TransferImportError.count }
        let directory = try TransferStaging.newDirectory()
        do {
            var items: [TransferAttachment] = []
            var textFiles: [URL] = []
            var total: Int64 = 0
            var suggestedTitle: String?
            for provider in providers {
                guard !provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier),
                      !provider.hasItemConformingToTypeIdentifier(UTType.package.identifier) else { throw TransferImportError.folders }
                let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                let sub = try TransferStaging.newDirectory()
                defer { try? FileManager.default.removeItem(at: sub) }
                let item = try await attachment(provider, types: types, into: sub)
                if suggestedTitle == nil {
                    suggestedTitle = cleanTitle(provider.suggestedName)
                    if suggestedTitle == nil, item.kind == .text {
                        let input = try FileHandle(forReadingFrom: sub.appending(path: item.name))
                        defer { try? input.close() }
                        // A title is a short preview, never an unbounded text read.
                        let prefix = try input.read(upToCount: 4096) ?? Data()
                        suggestedTitle = cleanTitle(String(decoding: prefix, as: UTF8.self)
                            .components(separatedBy: .newlines).first)
                    }
                }
                total += item.bytes
                guard total <= TransferManifest.maximumTransferBytes else { throw TransferImportError.size }
                if item.kind == .text {
                    // Keep each source in its own temp file until body assembly.
                    let url = directory.appending(path: ".text-\(textFiles.count)")
                    try FileManager.default.moveItem(at: sub.appending(path: item.name), to: url)
                    textFiles.append(url)
                } else {
                    let copied = try TransferStaging.copy(sub.appending(path: item.name), name: item.name,
                                                          uti: item.uti, kind: item.kind, into: directory)
                    items.append(copied)
                }
            }
            if !textFiles.isEmpty {
                let body = directory.appending(path: TransferCodec.bodyFileName)
                FileManager.default.createFile(atPath: body.path, contents: nil)
                let out = try FileHandle(forWritingTo: body)
                defer { try? out.close() }
                var size: Int64 = 0
                for (index, url) in textFiles.enumerated() {
                    if index > 0 {
                        size += 2; total += 2
                        guard size <= TransferManifest.maximumAttachmentBytes,
                              total <= TransferManifest.maximumTransferBytes else { throw TransferImportError.size }
                        try out.write(contentsOf: Data("\n\n".utf8))
                    }
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        size += Int64(chunk.count)
                        guard size <= TransferManifest.maximumAttachmentBytes, total <= TransferManifest.maximumTransferBytes else { throw TransferImportError.size }
                        try out.write(contentsOf: chunk)
                    }
                    try FileManager.default.removeItem(at: url)
                }
                items.insert(.init(name: "body.txt", uti: UTType.utf8PlainText.identifier, bytes: size, kind: .text), at: 0)
            }
            return TransferDraft(directory: directory, attachments: items,
                                 suggestedTitle: suggestedTitle ?? String(localized: "Transfer"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func cleanTitle(_ value: String?) -> String? {
        let title = value?.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    private static func attachment(_ provider: NSItemProvider, types: [UTType],
                                   into directory: URL) async throws -> TransferAttachment {
        // Hosts may advertise URL alongside text or images without being able
        // to vend that URL. Each representation is optional; safety errors are not.
        for type in [UTType.utf8PlainText, .plainText]
            where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let item = try await representation(provider, type: type, kind: .text, into: directory) { return item }
        }
        let images = types.filter { $0.conforms(to: .image) && $0 != .image }
            + (provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? [.image] : [])
        for type in images {
            if let item = try await representation(provider, type: type, kind: .image, into: directory) { return item }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let item = try await attempt(into: directory, { try await fileURL(provider, into: $0) }) { return item }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let item = try await attempt(into: directory, { try await urlText(provider, into: $0) }) { return item }
        for type in types where type.conforms(to: .data) && !type.conforms(to: .text)
            && !type.conforms(to: .url) && !type.conforms(to: .image) {
            // RTF/HTML without plain text are not flattened implicitly.
            if let item = try await representation(provider, type: type, kind: .file, into: directory) { return item }
        }
        throw TransferImportError.unsupported
    }

    private static func representation(_ provider: NSItemProvider, type: UTType, kind: TransferAttachment.Kind,
                                       into directory: URL) async throws -> TransferAttachment? {
        if let item = try await attempt(into: directory, { try await file(provider, type: type, kind: kind, into: $0) }) {
            return item
        }
        if let item = try await attempt(into: directory, { try await inlineItem(provider, type: type, kind: kind, into: $0) }) {
            return item
        }
        return try await attempt(into: directory) { directory in
            let name = provider.suggestedName
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    do {
                        guard let data else { throw TransferImportError.unavailable }
                        continuation.resume(returning: try write(data, name: name, type: type, kind: kind, into: directory))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// A failed representation can leave partial output (including body.txt).
    /// Isolate every try so fallback cannot collide with those files.
    private static func attempt(into directory: URL,
                                _ load: (URL) async throws -> TransferAttachment) async throws -> TransferAttachment? {
        let staging = try TransferStaging.newDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let item = try await load(staging)
            try FileManager.default.moveItem(at: staging.appending(path: item.name),
                                             to: directory.appending(path: item.name))
            return item
        } catch TransferImportError.unavailable { return nil }
        catch TransferImportError.unsupported { return nil }
    }

    private static func file(_ provider: NSItemProvider, type: UTType, kind: TransferAttachment.Kind,
                             into directory: URL) async throws -> TransferAttachment {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                do {
                    guard let url else { throw TransferImportError.unavailable }
                    // The provider owns this URL only for the callback's lifetime.
                    continuation.resume(returning: try copy(url, name: suggestedName, type: type, kind: kind, into: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func inlineItem(_ provider: NSItemProvider, type: UTType, kind: TransferAttachment.Kind,
                                   into directory: URL) async throws -> TransferAttachment {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                do {
                    let item: TransferAttachment
                    if let url = value as? URL, url.isFileURL {
                        item = try copy(url, name: suggestedName, type: type, kind: kind, into: directory)
                    } else if kind == .text, let text = value as? String {
                        guard text.utf8.count <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
                        item = try write(Data(text.utf8), name: suggestedName, type: type, kind: kind, into: directory)
                    } else if let data = value as? Data {
                        item = try write(data, name: suggestedName, type: type, kind: kind, into: directory)
                    } else if kind == .image, let image = value as? UIImage {
                        let isJPEG = type.conforms(to: .jpeg)
                        guard let data = isJPEG ? image.jpegData(compressionQuality: 1) : image.pngData() else {
                            throw TransferImportError.unavailable
                        }
                        item = try write(data, name: suggestedName, type: isJPEG ? .jpeg : .png, kind: kind, into: directory)
                    } else { throw TransferImportError.unavailable }
                    continuation.resume(returning: item)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func filename(_ suggested: String?, fallback: String, type: UTType) -> String {
        var name = suggested?.isEmpty == false ? suggested! : fallback
        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
        return name
    }

    nonisolated private static func copy(_ url: URL, name: String?, type: UTType, kind: TransferAttachment.Kind,
                                        into directory: URL) throws -> TransferAttachment {
        let item = try TransferStaging.copy(url, name: kind == .text ? "body.txt" : filename(name, fallback: url.lastPathComponent, type: type),
                                            uti: kind == .text ? UTType.utf8PlainText.identifier : type.identifier,
                                            kind: kind, into: directory)
        return try normalized(item, into: directory)
    }

    nonisolated private static func write(_ data: Data, name: String?, type: UTType, kind: TransferAttachment.Kind,
                                         into directory: URL) throws -> TransferAttachment {
        guard Int64(data.count) <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
        let name = kind == .text ? "body.txt" : filename(name, fallback: kind == .image ? "image" : "attachment", type: type)
        guard TransferAttachment.isSafeName(name), kind == .text || name.lowercased() != "body.txt" else {
            throw TransferImportError.duplicate
        }
        let url = directory.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 * 1024, data.count)
            try output.write(contentsOf: data.subdata(in: offset..<end))
            offset = end
        }
        try output.close()
        return try normalized(.init(name: name, uti: kind == .text ? UTType.utf8PlainText.identifier : type.identifier,
                                    bytes: Int64(data.count), kind: kind), into: directory)
    }

    nonisolated private static func normalized(_ item: TransferAttachment, into directory: URL) throws -> TransferAttachment {
        let url = directory.appending(path: item.name)
        if item.kind == .text { try TransferStaging.normalizeText(at: url) }
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(bytes) <= TransferManifest.maximumAttachmentBytes else { throw TransferImportError.size }
        return .init(name: item.name, uti: item.uti, bytes: Int64(bytes), kind: item.kind)
    }

    private static func fileURL(_ provider: NSItemProvider, into directory: URL) async throws -> TransferAttachment {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                do {
                    guard let url = value as? URL, url.isFileURL else { throw TransferImportError.unavailable }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
                    guard values.isDirectory != true, values.isPackage != true else { throw TransferImportError.folders }
                    let type = values.contentType ?? .data
                    if type.conforms(to: .text), !type.conforms(to: .plainText) { throw TransferImportError.unsupported }
                    let kind: TransferAttachment.Kind = type.conforms(to: .plainText) ? .text : type.conforms(to: .image) ? .image : .file
                    continuation.resume(returning: try copy(url, name: url.lastPathComponent, type: type, kind: kind, into: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func urlText(_ provider: NSItemProvider, into directory: URL) async throws -> TransferAttachment {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                do {
                    let url: URL?
                    if let value = value as? URL { url = value }
                    else if let value = value as? String { url = URL(string: value) }
                    else if let value = value as? Data, let text = String(data: value, encoding: .utf8) { url = URL(string: text) }
                    else { url = nil }
                    guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                        throw TransferImportError.unsupported
                    }
                    continuation.resume(returning: try write(Data(url.absoluteString.utf8), name: nil, type: .utf8PlainText,
                                                             kind: .text, into: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
