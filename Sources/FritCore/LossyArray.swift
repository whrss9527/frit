import Foundation

/// Decodes an array element by element and leaves out elements that cannot
/// be read, for example a rule with a condition from a newer version of
/// Meno. Without it one unknown element would make all settings unreadable.
@propertyWrapper
public struct LossyArray<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode does not move on, so step over the element.
                _ = try container.decode(Skipped.self)
            }
        }
        wrappedValue = elements
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
