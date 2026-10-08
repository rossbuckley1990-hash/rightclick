import AppKit
import Darwin
import Foundation
import ImageIO
import RightClickProtocol
import Security
import UniformTypeIdentifiers

public extension ContentItem {
    var utType: UTType? { typeIdentifier.flatMap { UTType($0) } }
}

public struct MacOSHost: PlatformHost {
    public init() {}
    public var requiresMainThread: Bool { true }
    public var plainTextDescription: String? { UTType.plainText.localizedDescription }
    public var urlDescription: String? { UTType.url.localizedDescription }
    public func prepareApplication() {
        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited { app.setActivationPolicy(.accessory) }
    }
    public func refreshNativeServices() { NSUpdateDynamicServices() }
    public func imageObservation(path: String) -> PlatformImageObservation {
        let value = nativeImageObservation(path: path)
        return PlatformImageObservation(width: value.width, height: value.height, metadataValues: value.metadataValues)
    }
    public func fileItem(url: URL, isDirectory: Bool) -> ContentItem {
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .localizedTypeDescriptionKey, .isDirectoryKey,
        ])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let identifier = type?.identifier ?? (isDirectory ? UTType.folder.identifier : UTType.data.identifier)
        let resolved = UTType(identifier) ?? .data
        let kind: String
        if isDirectory || resolved.conforms(to: .folder) {
            kind = "directory"
        } else if resolved.conforms(to: .image) {
            kind = "image"
        } else if resolved.conforms(to: .pdf) {
            kind = "pdf"
        } else if resolved.conforms(to: .movie) || resolved.conforms(to: .video) {
            kind = "video"
        } else if resolved.conforms(to: .audio) {
            kind = "audio"
        } else if resolved.conforms(to: .text) || resolved.conforms(to: .plainText) {
            kind = "text_file"
        } else {
            kind = "file"
        }
        return ContentItem(
            kind: kind,
            display: url.path,
            path: url.path,
            typeIdentifier: identifier,
            typeDescription: values?.localizedTypeDescription ?? resolved.localizedDescription,
            byteCount: values?.fileSize,
            isDirectory: isDirectory || resolved.conforms(to: .folder)
        )
    }

    public func hasXattr(
        path: String,
        key: String
    ) -> Bool? {
        guard
            FileManager.default.fileExists(
                atPath: path
            )
        else {
            return nil
        }

        let size: Int = path.withCString {
            pathPointer in

            key.withCString {
                keyPointer in

                getxattr(
                    pathPointer,
                    keyPointer,
                    nil,
                    0,
                    0,
                    0
                )
            }
        }

        if size >= 0 {
            return true
        }

        if errno == ENOATTR {
            return false
        }

        return nil
    }

    private func nativeImageObservation(
        path: String
    ) -> (
        width: Int?,
        height: Int?,
        metadataValues: [String]?
    ) {
        let url = URL(
            fileURLWithPath: path
        )

        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL,
                nil
            ),
            let properties =
                CGImageSourceCopyPropertiesAtIndex(
                    source,
                    0,
                    nil
                )
        else {
            return (
                nil,
                nil,
                nil
            )
        }

        let dictionary =
            properties as NSDictionary

        let width = (
            dictionary[
                kCGImagePropertyPixelWidth
            ] as? NSNumber
        )?.intValue

        let height = (
            dictionary[
                kCGImagePropertyPixelHeight
            ] as? NSNumber
        )?.intValue

        var values: [String] = []

        // Basic ImageIO properties expose dimensions and some metadata,
        // but not every embedded metadata value.
        collectMetadataValues(
            dictionary,
            into: &values
        )

        // CGImageMetadata exposes the richer embedded metadata graph.
        // This is provider-independent: RIGHTCLICK observes whatever
        // metadata ImageIO reports for the file rather than knowing
        // anything about the application that acted on it.
        if let metadata =
            CGImageSourceCopyMetadataAtIndex(
                source,
                0,
                nil
            )
        {
            collectImageMetadata(
                metadata,
                into: &values
            )
        }

        return (
            width,
            height,
            values
        )
    }

    private func collectImageMetadata(
        _ metadata: CGImageMetadata,
        into values: inout [String]
    ) {
        let tags =
            (CGImageMetadataCopyTags(metadata)
                as? [CGImageMetadataTag])
            ?? []

        for tag in tags {
            collectImageMetadataTag(
                tag,
                into: &values
            )
        }
    }

    private func collectImageMetadataTag(
        _ tag: CGImageMetadataTag,
        into values: inout [String]
    ) {
        guard let value =
            CGImageMetadataTagCopyValue(tag)
        else {
            return
        }

        // Metadata values can themselves be arrays of metadata tags,
        // for example dc:creator. Walk those tags recursively rather
        // than trusting a container's debug description as evidence.
        if let childTags =
            value as? [CGImageMetadataTag]
        {
            for child in childTags {
                collectImageMetadataTag(
                    child,
                    into: &values
                )
            }

            return
        }

        if let array = value as? NSArray {
            // Arrays consisting of CGImageMetadataTag values are handled
            // by the typed [CGImageMetadataTag] branch above. Remaining
            // arrays contain ordinary metadata values and can be flattened.
            for element in array {
                collectMetadataValues(
                    element,
                    into: &values
                )
            }

            return
        }

        collectMetadataValues(
            value,
            into: &values
        )
    }

    private func collectMetadataValues(
        _ object: Any,
        into values: inout [String]
    ) {
        if let dictionary =
            object as? NSDictionary
        {
            for (_, value) in dictionary {
                collectMetadataValues(
                    value,
                    into: &values
                )
            }

            return
        }

        if let array =
            object as? NSArray
        {
            for value in array {
                collectMetadataValues(
                    value,
                    into: &values
                )
            }

            return
        }

        values.append(
            String(
                describing: object
            )
        )
    }
}
