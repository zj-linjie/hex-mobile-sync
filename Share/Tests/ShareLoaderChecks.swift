import Foundation
import HexMobileCore
import UniformTypeIdentifiers

/// Deterministically exercise hosts that cannot vend their advertised file/URL.
private final class Provider: NSItemProvider, @unchecked Sendable {
    let types: [String]
    let value: (String) -> NSSecureCoding?
    let data: (String) -> Data?
    let file: (String) -> URL?
    private(set) var requests: [String] = []

    init(_ types: [UTType], name: String? = nil,
         value: @escaping (String) -> NSSecureCoding? = { _ in nil },
         data: @escaping (String) -> Data? = { _ in nil },
         file: @escaping (String) -> URL? = { _ in nil }) {
        self.types = types.map(\.identifier)
        self.value = value
        self.data = data
        self.file = file
        super.init()
        suggestedName = name
    }

    override var registeredTypeIdentifiers: [String] { types }

    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        types.contains { type in
            type == typeIdentifier || (UTType(type)?.conforms(to: UTType(typeIdentifier) ?? .item) == true)
        }
    }

    override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void) -> Progress {
        requests.append("file:" + typeIdentifier)
        let url = file(typeIdentifier)
        completionHandler(url, url == nil ? TransferImportError.unavailable : nil)
        // The URL's lifetime ends at callback return, just like a real provider.
        if let url { try? FileManager.default.removeItem(at: url) }
        return Progress(totalUnitCount: 1)
    }

    override func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil,
        completionHandler: NSItemProvider.CompletionHandler? = nil) {
        requests.append("item:" + typeIdentifier)
        let item = value(typeIdentifier)
        completionHandler?(item, item == nil ? TransferImportError.unavailable : nil)
    }

    override func loadDataRepresentation(forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress {
        requests.append("data:" + typeIdentifier)
        let bytes = data(typeIdentifier)
        completionHandler(bytes, bytes == nil ? TransferImportError.unavailable : nil)
        return Progress(totalUnitCount: 1)
    }
}

@main
private enum ShareLoaderChecks {
    @MainActor
    static func main() async throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func body(_ draft: TransferDraft) throws -> String {
            try String(contentsOf: draft.directory.appending(path: "body.txt"), encoding: .utf8)
        }
        func expect(_ error: TransferImportError, _ providers: [NSItemProvider]) async throws {
            do {
                let draft = try await ShareLoader.load(providers)
                draft.discard()
                preconditionFailure("Expected import rejection")
            } catch let actual as TransferImportError {
                check(String(describing: actual) == String(describing: error), "Wrong import rejection")
            }
        }

        // Notes/WeChat plain text wins even if URL loading fails or yields a file URL.
        for url in [nil, NSURL(fileURLWithPath: "/unavailable-note")] as [NSURL?] {
            let provider = Provider([.url, .plainText], value: { type in
                type == UTType.plainText.identifier ? "First line\nSecond line" as NSString : url
            })
            let draft = try await ShareLoader.load([provider])
            defer { draft.discard() }
            let text = try body(draft)
            check(text == "First line\nSecond line", "Plain text body")
            check(draft.suggestedTitle == "First line", "First-line title")
            check(!provider.requests.contains("item:" + UTType.url.identifier), "URL must not precede text")
            passed += 1
        }

        let named = Provider([.utf8PlainText], name: "Named note", value: { _ in "Body" as NSString })
        let namedDraft = try await ShareLoader.load([named])
        check(namedDraft.suggestedTitle == "Named note", "Provider title")
        namedDraft.discard()
        passed += 1

        let utf16 = Data([0xff, 0xfe]) + "Text data".data(using: .utf16LittleEndian)!
        let textData = Provider([.plainText], data: { _ in utf16 })
        let textDraft = try await ShareLoader.load([textData])
        let textBody = try body(textDraft)
        check(textBody == "Text data", "UTF-16 normalized to UTF-8")
        textDraft.discard()
        passed += 1

        let imageBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        for useDataAPI in [false, true] {
            let image = Provider([.url, .png], value: { type in
                !useDataAPI && type == UTType.png.identifier ? imageBytes as NSData : nil
            }, data: { type in useDataAPI && type == UTType.png.identifier ? imageBytes : nil })
            let draft = try await ShareLoader.load([image])
            defer { draft.discard() }
            check(draft.attachments.count == 1 && draft.attachments[0].kind == .image, "Image attachment")
            check(draft.attachments[0].uti == UTType.png.identifier, "Original image UTI")
            let saved = try Data(contentsOf: draft.directory.appending(path: draft.attachments[0].name))
            check(saved == imageBytes, "Original image bytes")
            check(!draft.suggestedTitle.isEmpty, "Image title fallback")
            passed += 1
        }

        // Failed normalization must clean body.txt before trying the image.
        let fallback = Provider([.plainText, .png], value: { type in
            type == UTType.plainText.identifier ? Data([0xff]) as NSData : imageBytes as NSData
        })
        let fallbackDraft = try await ShareLoader.load([fallback])
        check(fallbackDraft.attachments[0].kind == .image, "Unsupported text falls through to image")
        fallbackDraft.discard()
        passed += 1

        for scheme in ["http", "https"] {
            let url = URL(string: "\(scheme)://example.com/note")!
            let draft = try await ShareLoader.load([Provider([.url], value: { _ in url as NSURL })])
            let text = try body(draft)
            check(text == url.absoluteString, "Web URL body")
            draft.discard()
            passed += 1
        }
        for url in [URL(fileURLWithPath: "/note"), URL(string: "wechat://note")!] {
            try await expect(.unsupported, [Provider([.url], value: { _ in url as NSURL })])
            passed += 1
        }
        try await expect(.unsupported, [Provider([.url])])
        passed += 1
        for type in [UTType.rtf, .html] {
            try await expect(.unsupported, [Provider([type], value: { _ in "rich" as NSString })])
            passed += 1
        }

        let directory = try TransferStaging.newDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appending(path: "note.txt")
        try Data("Temporary text".utf8).write(to: textURL)
        let fileText = Provider([.utf8PlainText], file: { _ in textURL })
        let fileDraft = try await ShareLoader.load([fileText])
        check(!FileManager.default.fileExists(atPath: textURL.path), "Provider removed temp file")
        let copiedBody = try body(fileDraft)
        check(copiedBody == "Temporary text", "Copied within callback")
        fileDraft.discard()
        passed += 1

        let regular = directory.appending(path: "document.bin")
        try Data([1, 2, 3]).write(to: regular)
        let regularDraft = try await ShareLoader.load([Provider([.fileURL], value: { _ in regular as NSURL })])
        check(regularDraft.attachments[0].name == "document.bin" && regularDraft.attachments[0].kind == .file, "Regular file URL")
        regularDraft.discard()
        passed += 1

        try await expect(.folders, [Provider([.folder, .plainText], value: { _ in "text" as NSString })])
        try await expect(.folders, [Provider([.fileURL], value: { _ in directory as NSURL })])
        try await expect(.count, Array(repeating: named, count: 11))
        passed += 3

        let oversized = directory.appending(path: "oversized.txt")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let out = try FileHandle(forWritingTo: oversized)
        try out.truncate(atOffset: UInt64(TransferManifest.maximumAttachmentBytes + 1))
        try out.close()
        try await expect(.size, [Provider([.utf8PlainText, .png], value: { _ in imageBytes as NSData }, file: { _ in oversized })])
        passed += 1

        let orderedText = Provider([.utf8PlainText, .plainText], value: { type in
            type == UTType.plainText.identifier ? "Plain fallback" as NSString : nil
        })
        let orderedDraft = try await ShareLoader.load([orderedText])
        let orderedBody = try body(orderedDraft)
        check(orderedBody == "Plain fallback", "UTF-8 unavailable falls through to plain text")
        check(orderedText.requests.first == "file:" + UTType.utf8PlainText.identifier, "UTF-8 tried first")
        orderedDraft.discard()
        passed += 1

        let originalText = NSItemProvider(item: "Native provider text" as NSString, typeIdentifier: UTType.plainText.identifier)
        let nativeDraft = try await ShareLoader.load([originalText])
        let nativeBody = try body(nativeDraft)
        check(nativeBody == "Native provider text", "Real NSItemProvider text")
        nativeDraft.discard()
        passed += 1

        let binaryDraft = try await ShareLoader.load([Provider([.data], name: "raw.bin", data: { _ in Data([1, 2, 3]) })])
        check(binaryDraft.attachments[0].kind == .file && binaryDraft.attachments[0].name == "raw.bin", "Other data as a file")
        binaryDraft.discard()
        passed += 1

        // Three regular 70 MiB files exceed the transfer limit without exceeding
        // the per-file limit. Sparse fixtures keep test setup inexpensive.
        var largeProviders: [NSItemProvider] = []
        for index in 0..<3 {
            let url = directory.appending(path: "large-\(index).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 70 * 1024 * 1024)
            try handle.close()
            largeProviders.append(Provider([.fileURL], value: { _ in url as NSURL }))
        }
        try await expect(.size, largeProviders)
        passed += 1

        let combined = try await ShareLoader.load([named, textData])
        let combinedText = try body(combined)
        check(combined.attachments.count == 1 && combinedText == "Body\n\nText data", "One share assembles one text body")
        combined.discard()
        passed += 1
        print("Passed \(passed) ShareLoader checks (macOS provider harness; UIImage encoding and sheet visuals excluded).")
    }
}
