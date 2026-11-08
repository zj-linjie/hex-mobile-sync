import Foundation

/// A finished dictation handed from the app to the keyboard through the
/// general pasteboard, independent of the transcription engine that produced it.
///
/// The app writes one pasteboard item with two representations: the plain
/// text (so any app can paste it) and this payload as JSON under
/// ``HexMobileIPC/pasteboardType``. The keyboard inserts ``text`` once per
/// ``id`` and ignores stale payloads (see ``isFresh(at:maxAge:)``).
///
/// JSON: `{ "schema_version": 1, "id": "UUID", "text": "…", "created_at": "…",
/// "locale": "it-IT", "engine": "on-device" }` (`locale` and `engine` optional).
public struct DictationPayload: Codable, Sendable, Hashable, Identifiable {
    /// The newest schema version this package reads and the one it writes.
    public static let currentSchemaVersion = 1
    /// Default maximum age for ``isFresh(at:maxAge:)``, in seconds.
    public static let defaultMaxAge: TimeInterval = 120

    /// Schema version of the payload.
    public var schemaVersion: Int
    /// Identifier of the dictation (same as ``DictationRecord/id``).
    public var id: UUID
    /// The final text to insert.
    public var text: String
    /// When the dictation finished.
    public var createdAt: Date
    /// Recognition locale identifier, if known.
    public var locale: String?
    /// Identifier of the engine that produced the text (e.g. `on-device`), if known.
    public var engine: String?

    /// Creates a payload at the current schema version.
    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        locale: String? = nil,
        engine: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.locale = locale
        self.engine = engine
    }

    /// Creates the payload for a history record.
    public init(record: DictationRecord) {
        self.init(
            id: record.id,
            text: record.text,
            createdAt: record.createdAt,
            locale: record.locale,
            engine: record.engine
        )
    }

    /// Whether the payload is recent enough to insert at `now`.
    /// Payloads dated more than a few seconds in the future are rejected too.
    public func isFresh(at now: Date = Date(), maxAge: TimeInterval = defaultMaxAge) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age <= maxAge && age >= -5
    }

    /// ``text`` without control characters other than newline and tab, so a
    /// payload cannot send escape sequences or other invisible input to the
    /// focused field. Carriage returns become newlines.
    public var insertableText: String {
        Self.insertable(text)
    }

    /// Whether ``text`` contains a newline, which can submit a form or send a
    /// message in some apps.
    public var containsLineBreak: Bool {
        text.contains(where: \.isNewline)
    }

    /// `text` without control characters other than `\n` and `\t`.
    public static func insertable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                scalars.append(scalar)
                continue
            }
            if scalar.properties.generalCategory == .control || isBidiOverride(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Bidirectional overrides and isolates (U+202A–U+202E, U+2066–U+2069),
    /// which can make inserted text read differently from what it is.
    private static func isBidiOverride(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }

    /// The payload as JSON data.
    public func encoded() throws -> Data {
        try HexJSON.makeEncoder().encode(self)
    }

    /// Decodes a payload from pasteboard data.
    /// - Throws: ``SyncCodecError``.
    public static func decode(from data: Data) throws(SyncCodecError) -> DictationPayload {
        try SyncCodec.decode(DictationPayload.self, from: data)
    }

    /// Encodes an array of payloads (the recent-dictation loopback reply),
    /// with the same JSON conventions as ``encoded()``.
    public static func encodeArray(_ payloads: [DictationPayload]) throws -> Data {
        try HexJSON.makeEncoder().encode(payloads)
    }

    /// Decodes an array of payloads (see ``encodeArray(_:)``).
    /// - Throws: ``SyncCodecError``.
    public static func decodeArray(from data: Data) throws(SyncCodecError) -> [DictationPayload] {
        try SyncCodec.decode([DictationPayload].self, from: data)
    }

    /// A pasteboard item with the plain text and the JSON payload, suitable
    /// for `UIPasteboard.general.setItems([item])`.
    public func pasteboardItem() throws -> [String: Any] {
        [
            HexMobileIPC.plainTextPasteboardType: text,
            HexMobileIPC.pasteboardType: try encoded(),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case text
        case createdAt = "created_at"
        case locale
        case engine
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.validateSchemaVersion(
            forKey: .schemaVersion,
            supported: Self.currentSchemaVersion
        )
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        locale = container.decodeLenient(String.self, forKey: .locale)
        engine = container.decodeLenient(String.self, forKey: .engine)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(engine, forKey: .engine)
    }
}
