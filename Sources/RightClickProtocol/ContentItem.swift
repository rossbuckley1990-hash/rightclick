import Foundation

public struct ContentItem: Codable, Sendable, Equatable {
    public var kind: String
    public var display: String
    public var path: String?
    public var url: String?
    public var text: String?
    public var typeIdentifier: String?
    public var typeDescription: String?
    public var byteCount: Int?
    public var isDirectory: Bool

    public init(
        kind: String,
        display: String,
        path: String? = nil,
        url: String? = nil,
        text: String? = nil,
        typeIdentifier: String? = nil,
        typeDescription: String? = nil,
        byteCount: Int? = nil,
        isDirectory: Bool = false
    ) {
        self.kind = kind
        self.display = display
        self.path = path
        self.url = url
        self.text = text
        self.typeIdentifier = typeIdentifier
        self.typeDescription = typeDescription
        self.byteCount = byteCount
        self.isDirectory = isDirectory
    }

}

public struct RightClickError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
