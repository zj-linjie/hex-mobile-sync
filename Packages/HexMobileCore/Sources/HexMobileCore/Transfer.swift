import Foundation

/// The phone is the sole writer of manifests; receipts belong to the Mac.
public struct TransferManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let maximumAttachments = 10
    public static let maximumAttachmentBytes: Int64 = 100 * 1024 * 1024
    public static let maximumTransferBytes: Int64 = 200 * 1024 * 1024

    public enum Status: String, Codable, Sendable { case held, queued }
    public let schemaVersion: Int
    public let id: UUID
    public var status: Status
    public let createdAt: Date
    public var title: String
    public var note: String
    public let attachments: [TransferAttachment]

    public init(id: UUID = UUID(), status: Status, createdAt: Date = Date(), title: String,
                note: String = "", attachments: [TransferAttachment]) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.status = status
        self.createdAt = createdAt
        self.title = title
        self.note = note
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, status, createdAt = "created_at", title, note, attachments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.validateSchemaVersion(forKey: .schemaVersion, supported: Self.currentSchemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        status = try c.decode(Status.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        title = try c.decode(String.self, forKey: .title)
        note = try c.decode(String.self, forKey: .note)
        attachments = c.decodeLossyArray(TransferAttachment.self, forKey: .attachments)
        try validate()
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.contains(where: \.isNewline), note.count <= 200,
              !attachments.isEmpty, attachments.count <= Self.maximumAttachments,
              Set(attachments.map { $0.name.lowercased() }).count == attachments.count,
              attachments.allSatisfy(\.isValid),
              attachments.reduce(Int64(0), { $0 + $1.bytes }) <= Self.maximumTransferBytes else {
            throw SyncCodecError.invalidJSON("Invalid transfer title, note, attachments or size limits.")
        }
    }
}

public struct TransferAttachment: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case text, image, file }
    public let name: String
    public let uti: String
    public let bytes: Int64
    public let kind: Kind

    public init(name: String, uti: String, bytes: Int64, kind: Kind) {
        self.name = name
        self.uti = uti
        self.bytes = bytes
        self.kind = kind
    }

    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !["manifest.json", "receipt.json"].contains(name.lowercased())
    }

    public var isValid: Bool {
        Self.isSafeName(name) && !uti.isEmpty && bytes >= 0
            && bytes <= TransferManifest.maximumAttachmentBytes
            && (kind != .text || name == "body.txt")
            && (kind == .text || name.lowercased() != "body.txt")
    }

    enum CodingKeys: String, CodingKey { case name, uti, bytes, kind }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        uti = try c.decode(String.self, forKey: .uti)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        kind = try c.decode(Kind.self, forKey: .kind)
        guard isValid else { throw SyncCodecError.invalidJSON("Invalid transfer attachment.") }
    }
}

public struct TransferReceipt: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let deliveredAt: Date
    public let hexVersion: String

    public init(id: UUID, deliveredAt: Date, hexVersion: String) {
        schemaVersion = 1
        self.id = id
        self.deliveredAt = deliveredAt
        self.hexVersion = hexVersion
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, deliveredAt = "delivered_at", hexVersion = "hex_version"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.validateSchemaVersion(forKey: .schemaVersion, supported: 1)
        id = try c.decode(UUID.self, forKey: .id)
        deliveredAt = try c.decode(Date.self, forKey: .deliveredAt)
        hexVersion = try c.decode(String.self, forKey: .hexVersion)
        guard !hexVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncCodecError.invalidJSON("Incomplete transfer receipt.")
        }
    }
}

public enum TransferCodec {
    public static let directoryName = "transfers"
    public static let manifestFileName = "manifest.json"
    public static let receiptFileName = "receipt.json"
    public static let bodyFileName = "body.txt"

    public static func decodeManifest(from data: Data) throws(SyncCodecError) -> TransferManifest {
        try SyncCodec.decode(TransferManifest.self, from: data)
    }
    public static func decodeReceipt(from data: Data) throws(SyncCodecError) -> TransferReceipt {
        try SyncCodec.decode(TransferReceipt.self, from: data)
    }
    public static func encode(_ manifest: TransferManifest) throws -> Data {
        try manifest.validate()
        return try HexJSON.makeEncoder().encode(manifest)
    }
    /// Useful to consumers/tests; the iPhone never writes this to the sync folder.
    public static func encode(_ receipt: TransferReceipt) throws -> Data {
        try HexJSON.makeEncoder().encode(receipt)
    }
}
