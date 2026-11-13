import Foundation
import Testing
@testable import HexMobileCore

@Suite("Transfer codec")
struct TransferCodecTests {
    let id = UUID(uuidString: "187eb30d-caca-4567-8f9b-e44c37b852a3")!
    var manifest: TransferManifest {
        TransferManifest(id: id, status: .held, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                         title: "A note", attachments: [.init(name: "body.txt", uti: "public.utf8-plain-text", bytes: 4, kind: .text)])
    }
    func object() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: TransferCodec.encode(manifest)) as? [String: Any])
    }
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func roundTrip() throws {
        #expect(try TransferCodec.decodeManifest(from: TransferCodec.encode(manifest)) == manifest)
        let o = try object()
        #expect(o["schema_version"] as? Int == 1)
        #expect((o["created_at"] as? String)?.hasSuffix("Z") == true)
        #expect(o["note"] as? String == "")
        let receipt = TransferReceipt(id: id, deliveredAt: manifest.createdAt, hexVersion: "3.1.1")
        #expect(try TransferCodec.decodeReceipt(from: TransferCodec.encode(receipt)) == receipt)
    }
    @Test func missingSchemaRefused() throws {
        var o = try object(); o.removeValue(forKey: "schema_version")
        #expect(throws: SyncCodecError.missingSchemaVersion) { try TransferCodec.decodeManifest(from: data(o)) }
    }
    @Test func newerSchemaHardRefused() throws {
        var o = try object(); o["schema_version"] = 2; o["attachments"] = [7]
        #expect(throws: SyncCodecError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try TransferCodec.decodeManifest(from: data(o))
        }
        #expect(throws: SyncCodecError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try TransferCodec.decodeReceipt(from: Data(#"{"schema_version":2}"#.utf8))
        }
    }
    @Test func unknownKeysIgnoredAndBadItemsSkipped() throws {
        var o = try object(); o["future"] = ["value": 3]
        var a = try #require(o["attachments"] as? [[String: Any]])
        a[0]["future"] = true
        o["attachments"] = [7, ["name": "missing"], a[0], ["name": "../bad", "uti": "public.data", "bytes": 1, "kind": "file"]]
        #expect(try TransferCodec.decodeManifest(from: data(o)) == manifest)
    }
    @Test func incompleteReceiptRefused() throws {
        #expect(throws: SyncCodecError.self) {
            try TransferCodec.decodeReceipt(from: Data(#"{"schema_version":1,"id":"187eb30d-caca-4567-8f9b-e44c37b852a3"}"#.utf8))
        }
    }
    @Test func invalidTransfersRefused() throws {
        for key in ["status", "created_at", "title", "attachments"] {
            var o = try object(); o.removeValue(forKey: key)
            #expect(throws: SyncCodecError.self) { try TransferCodec.decodeManifest(from: data(o)) }
        }
        var o = try object(); o["note"] = String(repeating: "a", count: 201)
        #expect(throws: SyncCodecError.self) { try TransferCodec.decodeManifest(from: data(o)) }
        o = try object(); o["attachments"] = Array(repeating: ["name": "x", "uti": "public.data", "bytes": 1, "kind": "file"], count: 11)
        #expect(throws: SyncCodecError.self) { try TransferCodec.decodeManifest(from: data(o)) }
    }
    @Test func byteLimitsAndNames() throws {
        var m = manifest
        m.title = "Two\nlines"
        #expect(throws: SyncCodecError.self) { try TransferCodec.encode(m) }
        let large = TransferAttachment(name: "large.bin", uti: "public.data", bytes: TransferManifest.maximumAttachmentBytes + 1, kind: .file)
        #expect(!large.isValid)
        let items = (1...3).map { TransferAttachment(name: "\($0).bin", uti: "public.data", bytes: TransferManifest.maximumAttachmentBytes, kind: .file) }
        #expect(throws: SyncCodecError.self) { try TransferCodec.encode(TransferManifest(status: .held, title: "Large", attachments: items)) }
        for name in ["..", "a/b", "a\\b", "receipt.json", "manifest.json", "bad\u{0}"] {
            #expect(!TransferAttachment.isSafeName(name))
        }
    }
}
