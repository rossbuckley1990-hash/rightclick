import Foundation
import XCTest

final class FixtureLineFramingTests: XCTestCase {
    func testLFCRLFAndMixedRecordsPreserveEveryObject() throws {
        let first = Data(#"{"index":1,"text":"日本語😀"}"#.utf8)
        let second = Data(#"{"index":2,"text":"other"}"#.utf8)
        for (between, ending) in [("\n", "\n"), ("\r\n", "\r\n"), ("\r\n", "\n"), ("\n", "\r\n")] {
            let journal = first + Data(between.utf8) + second + Data(ending.utf8)
            XCTAssertEqual(try FixtureLineFraming.records(in: journal), [first, second])
            let rows = try FixtureLineFraming.objects(in: journal)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["index"] as? Int, 1)
            XCTAssertEqual(rows[1]["index"] as? Int, 2)
            XCTAssertEqual(rows[0]["text"] as? String, "日本語😀")
        }
    }

    func testEmptyAndUnterminatedFinalRecordAreDistinctFromBlankRecords() throws {
        XCTAssertEqual(try FixtureLineFraming.records(in: Data()), [])
        let first = Data("first".utf8), second = Data("second".utf8)
        XCTAssertEqual(try FixtureLineFraming.records(in: first), [first])
        XCTAssertEqual(try FixtureLineFraming.records(in: first + Data("\r\n".utf8) + second), [first, second])
        for value in ["\n", "\r\n", "first\n\n", "first\r\n\r\n", "first\n\nsecond"] {
            XCTAssertThrowsError(try FixtureLineFraming.records(in: Data(value.utf8))) {
                XCTAssertEqual($0 as? FixtureLineFraming.Failure, .emptyRecord)
            }
        }
    }

    func testBareOrRepeatedCarriageReturnsAreRejected() {
        for value in ["first\r", "first\rsecond\n", "first\r\r\n", "first\nsecond\r"] {
            XCTAssertThrowsError(try FixtureLineFraming.records(in: Data(value.utf8))) {
                XCTAssertEqual($0 as? FixtureLineFraming.Failure, .invalidLineEnding)
            }
        }
    }

    func testMalformedJSONAndNonObjectRecordsFailWithoutPrivateBytes() {
        let privateValue = "fixture-private-sentinel"
        for data in [Data(("{\"secret\":\"" + privateValue + "\"").utf8), Data([0xff]), Data("{}{}\n".utf8)] {
            XCTAssertThrowsError(try FixtureLineFraming.objects(in: data)) {
                XCTAssertEqual($0 as? FixtureLineFraming.Failure, .invalidJSON)
                XCTAssertFalse(String(describing: $0).contains(privateValue))
            }
        }
        for value in ["[]", "null", "1", #""text""#] {
            XCTAssertThrowsError(try FixtureLineFraming.objects(in: Data(value.utf8))) {
                XCTAssertEqual($0 as? FixtureLineFraming.Failure, .nonObjectJSON)
            }
        }
    }

    func testUnicodeLineCharactersAndEscapedCRLFArePayloadNotFraming() throws {
        let journal = Data("{\"text\":\"one\u{0085}two\u{2028}three\\r\\nfour\"}\r\n{}\n".utf8)
        let rows = try FixtureLineFraming.objects(in: journal)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["text"] as? String, "one\u{0085}two\u{2028}three\r\nfour")
    }

    func testMissingJournalIsEmptyButMalformedExistingJournalFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-line-framing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.jsonl")
        XCTAssertTrue(try FixtureLineFraming.objects(at: file).isEmpty)
        try Data("{}\r\n{}\r\n".utf8).write(to: file)
        XCTAssertEqual(try FixtureLineFraming.objects(at: file).count, 2)
        try Data("{}{}\n".utf8).write(to: file)
        XCTAssertThrowsError(try FixtureLineFraming.objects(at: file)) {
            XCTAssertEqual($0 as? FixtureLineFraming.Failure, .invalidJSON)
        }
        XCTAssertThrowsError(try FixtureLineFraming.objects(at: directory))
    }
}
