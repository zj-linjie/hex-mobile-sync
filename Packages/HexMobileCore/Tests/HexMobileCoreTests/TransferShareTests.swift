import Foundation
import Testing
@testable import HexMobileCore

@Suite("Transfer share")
struct TransferShareTests {
    let id = UUID(uuidString: "187eb30d-caca-4567-8f9b-e44c37b852a3")!

    @Test func noteAndBodyPrecedeFileCopiesWithoutChangingTheSource() throws {
        let source = try fixture(status: .queued, note: "Bring this", body: "Hello", files: ["photo.jpg": Data([1, 2, 3])])
        let before = try Data(contentsOf: source.appending(path: "manifest.json"))
        try Data(#"{"schema_version":1}"#.utf8).write(to: source.appending(path: "receipt.json"))
        try Data([9]).write(to: source.appending(path: "extra.bin"))
        let destination = try emptyDirectory()
        let prepared = try TransferShare.prepare(source: source, destination: destination)
        #expect(prepared.text == "Bring this\n\nHello")
        #expect(prepared.files.map(\.lastPathComponent) == ["photo.jpg"])
        #expect(try Data(contentsOf: prepared.files[0]) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: source.appending(path: "manifest.json")) == before)
        #expect(try Data(contentsOf: source.appending(path: "photo.jpg")) == Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "body.txt").path))
        let names = try fileNames(destination)
        #expect(names == ["photo.jpg"])
    }

    @Test func bodyOnlyAndFilesOnly() throws {
        let textOnly = try fixture(status: .held, note: "", body: "Only text", files: [:])
        let text = try TransferShare.prepare(source: textOnly, destination: try emptyDirectory())
        #expect(text.text == "Only text")
        #expect(text.files.isEmpty)

        let filesOnly = try fixture(status: .queued, note: "", body: nil, files: ["a.zip": Data([4]), "b.zip": Data([5, 6])])
        let files = try TransferShare.prepare(source: filesOnly, destination: try emptyDirectory())
        #expect(files.text == nil)
        #expect(files.files.map(\.lastPathComponent) == ["a.zip", "b.zip"])
    }

    @Test func noteWithoutBodyStaysText() throws {
        let source = try fixture(status: .held, note: "Just a note", body: nil, files: ["page.pdf": Data([7])])
        let prepared = try TransferShare.prepare(source: source, destination: try emptyDirectory())
        #expect(prepared.text == "Just a note")
        #expect(prepared.files.map(\.lastPathComponent) == ["page.pdf"])
    }

    @Test func incompleteFileSharesNothingAndKeepsTheSource() throws {
        let source = try fixture(status: .held, note: "Keep", body: "Body", files: ["good.bin": Data([1]), "bad.bin": Data([2, 3])])
        let bad = source.appending(path: "bad.bin")
        try Data([2]).write(to: bad)
        let before = try Data(contentsOf: source.appending(path: "manifest.json"))
        let destination = try emptyDirectory()
        #expect(throws: TransferShare.Failure.unavailable) {
            try TransferShare.prepare(source: source, destination: destination)
        }
        #expect(try fileNames(destination).isEmpty)
        #expect(try Data(contentsOf: source.appending(path: "manifest.json")) == before)
        #expect(try Data(contentsOf: source.appending(path: "good.bin")) == Data([1]))
    }

    @Test func missingFileDoesNotLeaveAPartialCopy() throws {
        let source = try fixture(status: .queued, note: "", body: nil, files: ["first.bin": Data([1]), "second.bin": Data([2])])
        try FileManager.default.removeItem(at: source.appending(path: "second.bin"))
        let destination = try emptyDirectory()
        #expect(throws: TransferShare.Failure.unavailable) {
            try TransferShare.prepare(source: source, destination: destination)
        }
        #expect(try fileNames(destination).isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "first.bin").path))
    }

    @Test func invalidBodyAndSymlinkShareNothing() throws {
        let invalid = try fixture(status: .held, note: "", body: "x", files: ["picture.png": Data([8])])
        try Data([0xFF]).write(to: invalid.appending(path: "body.txt"))
        let invalidDestination = try emptyDirectory()
        #expect(throws: TransferShare.Failure.unavailable) {
            try TransferShare.prepare(source: invalid, destination: invalidDestination)
        }
        #expect(try fileNames(invalidDestination).isEmpty)

        let linked = try fixture(status: .held, note: "", body: nil, files: ["linked.bin": Data([1])])
        let outside = linked.deletingLastPathComponent().appending(path: "outside.bin")
        try Data([1, 1]).write(to: outside)
        try FileManager.default.removeItem(at: linked.appending(path: "linked.bin"))
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "linked.bin"), withDestinationURL: outside)
        let linkedDestination = try emptyDirectory()
        #expect(throws: TransferShare.Failure.unavailable) {
            try TransferShare.prepare(source: linked, destination: linkedDestination)
        }
        #expect(try fileNames(linkedDestination).isEmpty)
        let values = try linked.appending(path: "linked.bin").resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
    }

    private func fixture(status: TransferManifest.Status, note: String, body: String?, files: [String: Data]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hex-share-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attachments: [TransferAttachment] = []
        if let body {
            let data = Data(body.utf8)
            try data.write(to: directory.appending(path: "body.txt"))
            attachments.append(.init(name: "body.txt", uti: "public.utf8-plain-text", bytes: Int64(data.count), kind: .text))
        }
        for name in files.keys.sorted() {
            let data = files[name]!
            try data.write(to: directory.appending(path: name))
            attachments.append(.init(name: name, uti: "public.data", bytes: Int64(data.count), kind: .file))
        }
        let manifest = TransferManifest(id: id, status: status, title: "Title", note: note, attachments: attachments)
        try TransferCodec.encode(manifest).write(to: directory.appending(path: "manifest.json"))
        return directory
    }

    private func emptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hex-share-out-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileNames(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
    }
}
