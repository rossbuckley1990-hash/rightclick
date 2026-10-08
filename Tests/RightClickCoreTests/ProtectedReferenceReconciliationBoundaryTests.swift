#if os(macOS) || os(Linux)
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RightClickCore
@testable import RightClickProtocol
@testable import RightClickProviders

/// Native dummy files exercise the credential/signing reference reader itself.
/// Journal-specific validators are deliberately not used as the assertion.
final class ProtectedReferenceReconciliationBoundaryTests: XCTestCase {
    private var root: URL!
    private let dummy = Data("owned-dummy-authority-reference".utf8)

    override func setUpWithError() throws {
        root = NativeHTTPFixture.temporaryDirectory.appendingPathComponent("protected-reference-boundary-" + UUID().uuidString)
        try NativeHTTPFixture.createPrivateDirectory(root)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func file(_ name: String, in directory: URL? = nil) throws -> URL {
        let value = (directory ?? root).appendingPathComponent(name)
        try NativeHTTPFixture.writePrivate(dummy, to: value)
        return value
    }

    private func denied(_ selected: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CapabilityProtectedReference.read(selected.path, maximum: 1024), file: file, line: line)
        XCTAssertThrowsError(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 1024), file: file, line: line)
    }

    func testValidPrivateReferenceAndBoundedSizeUseTheCommonNativeBackend() throws {
        let selected = try file("valid.raw")
        XCTAssertEqual(try CapabilityProtectedReference.read(selected.path, maximum: 1024), dummy)
        XCTAssertEqual(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 1024), dummy)
        XCTAssertThrowsError(try CapabilityProtectedReference.read(selected.path, maximum: 4))
        XCTAssertThrowsError(try RCIRHostConfiguration.protectedRead(selected.path, maximum: 4))
    }

    func testHardlinkedPrivateReferenceCannotBecomeSigningOrObserverAuthority() throws {
        let selected = try file("original.raw"), alias = root.appendingPathComponent("second-name.raw")
        XCTAssertEqual(link(selected.path, alias.path), 0)
        denied(selected); denied(alias)
        XCTAssertEqual(try Data(contentsOf: selected), dummy)
        XCTAssertEqual(try Data(contentsOf: alias), dummy)
    }

    func testFinalAndIntermediateSymlinksCannotRedirectProtectedAuthority() throws {
        let directory = root.appendingPathComponent("actual", isDirectory: true)
        try NativeHTTPFixture.createPrivateDirectory(directory)
        let selected = try file("reference.raw", in: directory)
        let finalAlias = root.appendingPathComponent("final.raw")
        let parentAlias = root.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: finalAlias, withDestinationURL: selected)
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: directory)
        denied(finalAlias); denied(parentAlias.appendingPathComponent("reference.raw"))
        XCTAssertEqual(try CapabilityProtectedReference.read(selected.path, maximum: 1024), dummy)
    }

    func testWritableNonStickyAncestorCannotSupplyProtectedAuthority() throws {
        let parent = root.appendingPathComponent("unsafe-parent", isDirectory: true)
        try NativeHTTPFixture.createPrivateDirectory(parent)
        let selected = try file("reference.raw", in: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        for mode in [0o770, 0o777] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: parent.path)
            denied(selected)
            XCTAssertEqual(try Data(contentsOf: selected), dummy)
        }
    }

#if os(macOS)
    private func acl(_ rule: String, at selected: URL) throws {
        _ = try BoundedCapabilityProcess.run(executable: URL(fileURLWithPath: "/bin/chmod"),
            arguments: ["+a", rule, selected.path], timeout: 3, maximumBytes: 4096)
    }

    func testDarwinExtendedReadAndWriteACLsCannotBypassPrivateReferenceModes() throws {
        for (index, rule) in ["everyone allow read", "everyone allow write", "everyone allow read,write"].enumerated() {
            let selected = try file("acl-\(index).raw")
            try acl(rule, at: selected)
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: selected.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue, 0o600)
            denied(selected)
        }
    }

    func testDarwinInheritedReadACLAndAncestorWriteACLCannotSupplyProtectedAuthority() throws {
        let inherited = root.appendingPathComponent("inherited", isDirectory: true)
        try NativeHTTPFixture.createPrivateDirectory(inherited)
        try acl("everyone allow read,file_inherit,directory_inherit", at: inherited)
        let selected = try file("reference.raw", in: inherited)
        denied(selected)
        let writable = root.appendingPathComponent("writable", isDirectory: true)
        try NativeHTTPFixture.createPrivateDirectory(writable)
        let another = try file("reference.raw", in: writable)
        try acl("everyone allow write,delete_child", at: writable)
        denied(another)
    }
#endif
}
#endif
