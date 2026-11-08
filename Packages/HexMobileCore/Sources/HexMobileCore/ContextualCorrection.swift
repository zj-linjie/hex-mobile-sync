import Foundation

/// An explicitly selected local correction, restricted by its following text and
/// a nearby context phrase. It never expands vocabulary aliases into rules.
public struct ContextualCorrection: Codable, Sendable, Hashable {
    public let heard: String
    public let replacement: String
    public let following: String
    public let context: String
    public let maxContextDistance: Int

    public init(heard: String, replacement: String, following: String, context: String, maxContextDistance: Int = 20) {
        self.heard = heard
        self.replacement = replacement
        self.following = following
        self.context = context
        self.maxContextDistance = maxContextDistance
    }

    public func apply(to text: String) -> String {
        guard !heard.isEmpty, !following.isEmpty, !context.isEmpty, maxContextDistance >= 0 else { return text }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex, let match = text.range(of: heard, range: cursor..<text.endIndex) {
            result += text[cursor..<match.lowerBound]
            let tail = text[match.upperBound...]
            let limit = text.index(match.upperBound, offsetBy: maxContextDistance, limitedBy: text.endIndex) ?? text.endIndex
            let window = text[match.upperBound..<limit]
            let beginsInsideASCIIWord: Bool = {
                guard match.lowerBound > text.startIndex,
                      let first = heard.unicodeScalars.first,
                      first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
                let previous = text[text.index(before: match.lowerBound)]
                return previous.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            }()
            if !beginsInsideASCIIWord, tail.hasPrefix(following), window.contains(context) {
                result += replacement
            } else {
                result += text[match]
            }
            cursor = match.upperBound
        }
        result += text[cursor...]
        return result
    }
}
