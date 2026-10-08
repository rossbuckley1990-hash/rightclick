import Foundation

/// Fixture journals are byte-framed. Swift Character treats CRLF as one
/// grapheme, so splitting a String on LF can combine distinct Windows records.
enum FixtureLineFraming {
    enum Failure: String, Error, CustomStringConvertible {
        case emptyRecord, invalidLineEnding, invalidJSON, nonObjectJSON
        var description: String { "Fixture line framing: \(rawValue)" }
    }

    static func records(in data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }
        let parts = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        var records: [Data] = []
        for (index, part) in parts.enumerated() {
            let terminated = index < parts.count - 1
            if part.isEmpty, !terminated { continue } // One final LF is optional.
            var record = Data(part)
            if terminated, record.last == 0x0d { record.removeLast() }
            guard !record.isEmpty else { throw Failure.emptyRecord }
            guard !record.contains(0x0d) else { throw Failure.invalidLineEnding }
            records.append(record)
        }
        return records
    }

    static func objects(in data: Data) throws -> [[String: Any]] {
        try records(in: data).map { record in
            let value: Any
            do { value = try JSONSerialization.jsonObject(with: record, options: [.fragmentsAllowed]) }
            catch { throw Failure.invalidJSON } // Never echo private journal bytes.
            guard let object = value as? [String: Any] else { throw Failure.nonObjectJSON }
            return object
        }
    }

    /// A journal may not exist before the first effect. Other read or parse
    /// failures must fail the test instead of being mistaken for zero effects.
    static func objects(at file: URL) throws -> [[String: Any]] {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try objects(in: data)
    }
}
