import Foundation

/// JSON decoding that tolerates missing keys by merging stored values over
/// the encoded defaults before decoding.
///
/// Nested objects are merged recursively; arrays and scalars in the stored
/// document replace the defaults. An object that shares no keys with its
/// default counterpart (for example a different case of an enum with
/// associated values) replaces it as a whole.
public enum TolerantJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Settings sections are structs even when they contain only future keys;
    /// pass mergeDisjointObjects to keep their known defaults in that case.
    public static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T, mergeDisjointObjects: Bool = false) throws -> T {
        let defaultData = try makeEncoder().encode(defaults)
        let base = try JSONSerialization.jsonObject(with: defaultData, options: [.fragmentsAllowed])
        let stored = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let merged = merge(base, stored, mergeDisjointObjects: mergeDisjointObjects)
        let mergedData = try JSONSerialization.data(withJSONObject: merged, options: [.fragmentsAllowed])
        return try makeDecoder().decode(T.self, from: mergedData)
    }

    static func merge(_ base: Any, _ override: Any, mergeDisjointObjects: Bool = false) -> Any {
        guard let baseObject = base as? [String: Any], let overrideObject = override as? [String: Any] else {
            return override
        }
        let sharesKeys = !Set(baseObject.keys).isDisjoint(with: overrideObject.keys)
        if !mergeDisjointObjects, !sharesKeys, !overrideObject.isEmpty, !baseObject.isEmpty {
            // Probably a different enum case: take the stored value as is.
            return overrideObject
        }
        var result = baseObject
        for (key, value) in overrideObject {
            if let existing = baseObject[key] {
                result[key] = merge(existing, value, mergeDisjointObjects: mergeDisjointObjects)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
