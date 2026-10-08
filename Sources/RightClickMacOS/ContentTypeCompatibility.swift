import RightClickProtocol
import RightClickProviders
import RightClickMacOSHost
import UniformTypeIdentifiers

public extension ContentParser {
    static func conforms(_ item: ContentItem, to other: UTType) -> Bool {
        guard let type = item.utType else { return false }
        return type.conforms(to: other) || type.identifier == other.identifier
    }
}
