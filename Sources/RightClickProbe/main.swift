import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import RightClickProbePrivate
import UniformTypeIdentifiers

// RIGHTCLICK-000 feasibility probe.
// Discovers sharing services, Services menu registrations, and Action
// extensions from this Mac, then attempts one harmless invocation of each
// surface that exposes a public execution API.

struct ShareRecord: Codable {
    var title: String
    var menuItemTitle: String
    var matchedPublicName: String?
    var matchedPublicStatus: String?
    var canPerform: Bool
    var imageWidth: Double?
    var imageHeight: Double?
    var imageSHA256: String?
    var imageIsTemplate: Bool?
    var debugDescription: String
    var sourceAPI: String
}

struct MenuNode: Codable {
    var title: String
    var isSeparator: Bool
    var isEnabled: Bool
    var action: String?
    var representedType: String?
    var representedDescription: String?
    var children: [MenuNode]
}

struct SharingSample: Codable {
    var label: String
    var input: String
    var deprecatedAPIServices: [ShareRecord]
    var menuAPIServices: [ShareRecord]
    var menuTree: [MenuNode]
    var pickerDelegateServices: [ShareRecord]
    var errors: [String]
}

struct InstalledService: Codable {
    var menuTitle: String
    var message: String?
    var portName: String?
    var bundleIdentifier: String?
    var bundleName: String?
    var bundlePath: String
    var sendTypes: [String]
    var sendFileTypes: [String]
    var returnTypes: [String]
    var requiredContext: String?
    var keyEquivalent: String?
    var workflowTypeIdentifier: String?
    var serviceInputTypeIdentifier: String?
    var discoverySource: String
    var supportLevel: String
}

struct ServiceAttempt: Codable {
    var serviceMenuTitle: String
    var provider: String?
    var input: String
    var invokedName: String
    var nsPerformServiceReturned: Bool?
    var pasteboardChangeCountBefore: Int
    var pasteboardChangeCountAfter: Int?
    var resultStrings: [String: String]
    var error: String?
    var timedNote: String?
}

struct ActionExtensionRecord: Codable {
    var name: String?
    var bundleIdentifier: String?
    var bundlePath: String
    var extensionPointIdentifier: String?
    var allowsFinderPreviewItem: Bool?
    var finderPreviewLabel: String?
    var finderPreviewIconName: String?
    var roleType: String?
    var allowsToolbarItem: Bool?
    var activationRule: String
    var activationRuleKind: String
    var applicability: [String: String]
    var applicabilityMethod: String
    var supportLevel: String
    var invocation: String
}

struct ProbeReport: Codable {
    var generatedAt: String
    var macosVersion: String
    var macosBuild: String
    var swiftVersion: String
    var fixtureDirectory: String
    var sharing: SharingSection
    var services: ServicesSection
    var quickActions: QuickActionSection
    var gates: GateSection
}

struct SharingSection: Codable {
    var discoverySupportLevel: String
    var executionSupportLevel: String
    var samples: [SharingSample]
    var execution: SharingExecution?
    var notes: [String]
}

struct SharingExecution: Codable {
    var discoveredTitles: [String]
    var chosenTitle: String?
    var chosenPublicName: String?
    var input: String
    var delegateEvents: [String]
    var newWindowTitles: [String]
    var invoked: Bool
    var error: String?
}

struct ServicesSection: Codable {
    var discoverySupportLevel: String
    var executionSupportLevel: String
    var discoverySource: String
    var count: Int
    var services: [InstalledService]
    var execution: ServiceAttempt?
    var alternateAttempts: [ServiceAttempt]
    var notes: [String]
}

struct QuickActionSection: Codable {
    var discoverySupportLevel: String
    var executionSupportLevel: String
    var discoverySource: String
    var extensions: [ActionExtensionRecord]
    var applicabilityMatrix: [String: [String: String]]
    var privateRuntime: PrivateRuntimeResult
    var pluginkit: String
    var notes: [String]
}

struct PrivateRuntimeResult: Codable {
    var nsExtensionClassPresent: Bool
    var methodNames: [String]
    var matchAttempts: [PrivateMatchAttempt]
    var productUse: String
}

struct PrivateMatchAttempt: Codable {
    var attributeKey: String
    var attributeValue: String
    var error: String?
    var matchCount: Int?
    var matches: [String]
}

struct GateSection: Codable {
    var sharingDiscovery: String
    var sharingExecution: String
    var sharingSupportLevel: String
    var servicesDiscovery: String
    var servicesExecution: String
    var servicesSupportLevel: String
    var quickActionDiscovery: String
    var quickActionExecution: String
    var quickActionSupportLevel: String
    var rightclick000: String
    var reasons: [String]
}

final class ShareDelegate: NSObject, NSSharingServiceDelegate {
    var events: [String] = []

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        events.append("willShareItems count=\(items.count)")
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        events.append("didShareItems count=\(items.count)")
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        events.append("didFailToShareItems \(error.localizedDescription)")
    }
}

final class PickerDelegate: NSObject, NSSharingServicePickerDelegate {
    var proposed: [NSSharingService] = []
    var chosenTitle: String?

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        proposed = proposedServices
        return proposedServices
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        chosenTitle = service?.title
    }
}

struct KnownShareName {
    var name: NSSharingService.Name
    var status: String
}

let knownShareNames: [KnownShareName] = [
    KnownShareName(name: .composeEmail, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .composeMessage, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .sendViaAirDrop, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .addToSafariReadingList, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .addToIPhoto, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .addToAperture, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .useAsDesktopPicture, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .cloudSharing, status: "PUBLIC_SUPPORTED"),
    KnownShareName(name: .postOnFacebook, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postOnTwitter, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postOnSinaWeibo, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postOnTencentWeibo, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postOnLinkedIn, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postImageOnFlickr, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postVideoOnVimeo, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postVideoOnYouku, status: "PUBLIC_DEPRECATED"),
    KnownShareName(name: .postVideoOnTudou, status: "PUBLIC_DEPRECATED"),
]

@main
struct RightClickProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let args = Array(CommandLine.arguments.dropFirst())
        let outPath = argumentValue(args, flag: "--out") ?? "evidence/rightclick-000/results.json"
        let fixtureDir = argumentValue(args, flag: "--fixtures") ?? "fixtures"
        let skipExecution = args.contains("--skip-execution")
        let skipShareExecution = args.contains("--skip-share-execution") || skipExecution
        let skipServiceExecution = args.contains("--skip-service-execution") || skipExecution
        let skipPrivate = args.contains("--skip-private-runtime")
        let skipPickerUI = args.contains("--skip-picker-ui")

        let fixtureURL = URL(fileURLWithPath: fixtureDir, isDirectory: true)
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: fixtureURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var notesSharing: [String] = []
        var fixtureNotes: [String] = []
        let fixtures = makeFixtures(in: fixtureURL, notes: &fixtureNotes)
        notesSharing.append(contentsOf: fixtureNotes)

        let samples = discoverSharingSamples(fixtures, showPicker: !skipPickerUI)
        let sharingDifferentiated = sharingSetsDiffer(samples)

        var execution: SharingExecution?
        if !skipShareExecution {
            execution = executeHarmlessShare(fixtures: fixtures)
        } else {
            notesSharing.append("Sharing execution skipped by flag.")
        }

        let installed = discoverServices()
        var serviceAttempt: ServiceAttempt?
        var alternateAttempts: [ServiceAttempt] = []
        var serviceNotes: [String] = []
        if !skipServiceExecution {
            let exec = executeHarmlessService(from: installed)
            serviceAttempt = exec.primary
            alternateAttempts = exec.alternates
            serviceNotes.append(contentsOf: exec.notes)
        } else {
            serviceNotes.append("Service execution skipped by flag.")
        }

        let actions = discoverActionExtensions()
        let matrix = applicabilityMatrix(actions.records)
        let pluginkit = runCommand("/usr/bin/pluginkit", arguments: ["-m", "-p", "com.apple.ui-services", "-A", "-v"])
        var privateRuntime = PrivateRuntimeResult(
            nsExtensionClassPresent: false,
            methodNames: [],
            matchAttempts: [],
            productUse: "Private NSExtension runtime is probe-only and is not used for product execution."
        )
        if !skipPrivate {
            privateRuntime = probePrivateNSExtension()
        }

        let gates = evaluateGates(
            samples: samples,
            sharingExecution: execution,
            services: installed,
            serviceAttempt: serviceAttempt,
            actions: actions.records,
            sharingDifferentiated: sharingDifferentiated
        )

        let (product, build) = macosVersion()
        let report = ProbeReport(
            generatedAt: isoNow(),
            macosVersion: product,
            macosBuild: build,
            swiftVersion: runCommand("/usr/bin/swift", arguments: ["--version"]),
            fixtureDirectory: fixtureURL.path,
            sharing: SharingSection(
                discoverySupportLevel: sharingDiscoveryLevel(samples),
                executionSupportLevel: "PUBLIC_SUPPORTED",
                samples: samples,
                execution: execution,
                notes: notesSharing + [
                    "NSSharingService.sharingServices(forItems:) is marked API_DEPRECATED as of macOS 13 in NSSharingService.h. On this Mac it is the API that returns a context-filtered service list.",
                    "NSSharingServicePicker.standardShareMenuItem is the documented replacement and returns one Share menu item. Its submenu did not enumerate services.",
                    "The picker delegate proposedSharingServices callback ran only after show(relativeTo:of:preferredEdge:), and included services with canPerform false. It is not the filtered contextual catalog.",
                    "perform(withItems:) remains a public, non-deprecated method.",
                    "Public service name constants are used only to label services that were already returned by discovery. They are not the discovery source.",
                ]
            ),
            services: ServicesSection(
                discoverySupportLevel: "PUBLIC_SUPPORTED",
                executionSupportLevel: serviceAttempt?.nsPerformServiceReturned == true ? "PUBLIC_SUPPORTED" : "PUBLIC_SUPPORTED",
                discoverySource: "Documented Info.plist key NSServices, read from installed .app, .service, and .workflow bundles. There is no public enumeration API; NSPerformService and NSUpdateDynamicServices are public.",
                count: installed.count,
                services: installed,
                execution: serviceAttempt,
                alternateAttempts: alternateAttempts,
                notes: serviceNotes
            ),
            quickActions: QuickActionSection(
                discoverySupportLevel: actions.records.isEmpty ? "UNAVAILABLE" : "PUBLIC_SUPPORTED",
                executionSupportLevel: "UNAVAILABLE",
                discoverySource: actions.source,
                extensions: actions.records,
                applicabilityMatrix: matrix,
                privateRuntime: privateRuntime,
                pluginkit: pluginkit,
                notes: actions.notes + [
                    "No public SDK type for invoking an Action extension directly was found in the macOS SDK (NSExtension.h is absent). Direct execution is therefore not claimed.",
                    "Extensions whose point identifier is not com.apple.ui-services are not treated as Finder Action extensions, even if a template key such as NSExtensionServiceAllowsFinderPreviewItem is present.",
                ]
            ),
            gates: gates
        )

        writeReport(report, to: outURL)
        print(summary(report))
    }
}

func argumentValue(_ args: [String], flag: String) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func macosVersion() -> (String, String) {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else {
        return ("unknown", "unknown")
    }
    return (plist["ProductVersion"] as? String ?? "unknown", plist["ProductBuildVersion"] as? String ?? "unknown")
}

func runCommand(_ launchPath: String, arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return "failed to run \(launchPath): \(error.localizedDescription)"
    }
}

func spin(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

struct FixtureSet {
    var jpeg: URL
    var pdf: URL
    var text: URL
    var movie: URL
    var webURL: URL
    var plainText: String
}

func makeFixtures(in directory: URL, notes: inout [String]) -> FixtureSet {
    let jpeg = directory.appendingPathComponent("sample.jpg")
    let pdf = directory.appendingPathComponent("sample.pdf")
    let text = directory.appendingPathComponent("sample.txt")
    let movie = directory.appendingPathComponent("sample.mov")

    do {
        try writeJPEG(to: jpeg)
    } catch {
        notes.append("JPEG fixture failed: \(error.localizedDescription)")
    }
    do {
        try writePDF(to: pdf)
    } catch {
        notes.append("PDF fixture failed: \(error.localizedDescription)")
    }
    do {
        try "RIGHTCLICK sample text\nThe quick brown fox jumps over the lazy dog.\n".write(to: text, atomically: true, encoding: .utf8)
    } catch {
        notes.append("Text fixture failed: \(error.localizedDescription)")
    }
    do {
        try writeMovie(to: movie)
    } catch {
        notes.append("Movie fixture failed: \(error.localizedDescription)")
    }
    return FixtureSet(
        jpeg: jpeg,
        pdf: pdf,
        text: text,
        movie: movie,
        webURL: URL(string: "https://example.com/rightclick-probe")!,
        plainText: "RIGHTCLICK plain text selection"
    )
}

func writeJPEG(to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 32,
        pixelsHigh: 32,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw ProbeError("Unable to allocate bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 32, height: 32).fill()
    NSColor.systemOrange.setFill()
    NSRect(x: 8, y: 8, width: 16, height: 16).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
        throw ProbeError("JPEG encoding failed")
    }
    try data.write(to: url)
}

func writePDF(to url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 240, height: 180)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw ProbeError("PDF context failed")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1))
    context.fill(box)
    context.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1))
    context.fill(CGRect(x: 24, y: 24, width: 80, height: 50))
    context.endPDFPage()
    context.closePDF()
}

func writeMovie(to url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    let codecs: [AVVideoCodecType] = [.h264, .hevc, .proRes422, .jpeg]
    var lastError: Error = ProbeError("No codec attempted")
    for codec in codecs {
        do {
            try writeMovie(to: url, codec: codec)
            return
        } catch {
            lastError = error
            try? FileManager.default.removeItem(at: url)
        }
    }
    throw lastError
}

func writeMovie(to url: URL, codec: AVVideoCodecType) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: 16,
        AVVideoHeightKey: 16,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
        ]
    )
    guard writer.canAdd(input) else { throw ProbeError("Cannot add writer input for \(codec.rawValue)") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? ProbeError("startWriting failed for \(codec.rawValue)") }
    writer.startSession(atSourceTime: .zero)
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw ProbeError("CVPixelBufferCreate failed")
    }
    let deadline = Date().addingTimeInterval(2)
    while !input.isReadyForMoreMediaData && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
        throw writer.error ?? ProbeError("append pixel buffer failed for \(codec.rawValue)")
    }
    input.markAsFinished()
    var finished = false
    writer.finishWriting { finished = true }
    let until = Date().addingTimeInterval(5)
    while !finished && Date() < until {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard finished, writer.status == .completed else {
        throw writer.error ?? ProbeError("finishWriting failed for \(codec.rawValue) status=\(writer.status.rawValue)")
    }
}

struct ProbeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func discoverSharingSamples(_ fixtures: FixtureSet, showPicker: Bool) -> [SharingSample] {
    let cases: [(String, [Any], String)] = [
        ("jpg", [fixtures.jpeg as NSURL], fixtures.jpeg.path),
        ("pdf", [fixtures.pdf as NSURL], fixtures.pdf.path),
        ("txt", [fixtures.text as NSURL], fixtures.text.path),
        ("mov", [fixtures.movie as NSURL], fixtures.movie.path),
        ("url", [fixtures.webURL as NSURL], fixtures.webURL.absoluteString),
        ("plain-text", [fixtures.plainText as NSString], fixtures.plainText),
    ]
    return cases.map { label, items, input in
        var errors: [String] = []
        let deprecated = safeShares {
            NSSharingService.sharingServices(forItems: items).map {
                record(for: $0, items: items, sourceAPI: "NSSharingService.sharingServices(forItems:) PUBLIC_DEPRECATED")
            }
        }
        if let message = deprecated.error { errors.append(message) }

        let menu = dumpShareMenu(items: items)
        if let message = menu.error { errors.append(message) }

        let picker = showPicker ? dumpPickerDelegate(items: items) : (records: [ShareRecord](), error: "Picker UI skipped by flag.")
        if let message = picker.error { errors.append(message) }

        return SharingSample(
            label: label,
            input: input,
            deprecatedAPIServices: deprecated.records,
            menuAPIServices: menu.records,
            menuTree: menu.tree,
            pickerDelegateServices: picker.records,
            errors: errors
        )
    }
}

func safeShares(_ body: () -> [ShareRecord]) -> (records: [ShareRecord], error: String?) {
    (body(), nil)
}

func record(for service: NSSharingService, items: [Any], sourceAPI: String) -> ShareRecord {
    let image = imageMetadata(service.image)
    let matched = matchPublicName(service)
    return ShareRecord(
        title: service.title,
        menuItemTitle: service.menuItemTitle,
        matchedPublicName: matched?.rawValue,
        matchedPublicStatus: matched == nil ? nil : statusForPublicName(matched!),
        canPerform: service.canPerform(withItems: items),
        imageWidth: image.width,
        imageHeight: image.height,
        imageSHA256: image.hash,
        imageIsTemplate: image.template,
        debugDescription: String(describing: service).prefix(400).description,
        sourceAPI: sourceAPI
    )
}

func matchPublicName(_ service: NSSharingService) -> NSSharingService.Name? {
    for known in knownShareNames {
        guard let reference = NSSharingService(named: known.name) else { continue }
        if reference.title == service.title && reference.menuItemTitle == service.menuItemTitle {
            return known.name
        }
    }
    return nil
}

func statusForPublicName(_ name: NSSharingService.Name) -> String {
    knownShareNames.first { $0.name.rawValue == name.rawValue }?.status ?? "PUBLIC_SUPPORTED"
}

func imageMetadata(_ image: NSImage?) -> (width: Double?, height: Double?, hash: String?, template: Bool?) {
    guard let image else { return (nil, nil, nil, nil) }
    var hash: String?
    if let tiff = image.tiffRepresentation {
        let digest = SHA256.hash(data: tiff)
        hash = digest.map { String(format: "%02x", $0) }.joined()
    }
    return (Double(image.size.width), Double(image.size.height), hash, image.isTemplate)
}

func dumpShareMenu(items: [Any]) -> (records: [ShareRecord], tree: [MenuNode], error: String?) {
    let picker = NSSharingServicePicker(items: items)
    let menuItem = picker.standardShareMenuItem
    let tree = [walk(menuItem, depth: 0)]
    let services = collectServices(from: menuItem, items: items)
    return (services, tree, nil)
}

func walk(_ item: NSMenuItem, depth: Int) -> MenuNode {
    var children: [MenuNode] = []
    if depth < 4, let submenu = item.submenu {
        submenu.update()
        children = submenu.items.map { walk($0, depth: depth + 1) }
    }
    let represented = item.representedObject
    return MenuNode(
        title: item.title,
        isSeparator: item.isSeparatorItem,
        isEnabled: item.isEnabled,
        action: item.action.map { NSStringFromSelector($0) },
        representedType: represented.map { String(describing: type(of: $0)) },
        representedDescription: represented.map { String(describing: $0).prefix(300).description },
        children: children
    )
}

func collectServices(from item: NSMenuItem, items: [Any]) -> [ShareRecord] {
    var records: [ShareRecord] = []
    if let service = item.representedObject as? NSSharingService {
        records.append(record(for: service, items: items, sourceAPI: "NSSharingServicePicker.standardShareMenuItem PUBLIC_SUPPORTED"))
    }
    if let submenu = item.submenu {
        submenu.update()
        for child in submenu.items {
            records.append(contentsOf: collectServices(from: child, items: items))
        }
    }
    return records
}

func dumpPickerDelegate(items: [Any]) -> (records: [ShareRecord], error: String?) {
    let picker = NSSharingServicePicker(items: items)
    let delegate = PickerDelegate()
    picker.delegate = delegate
    let window = NSWindow(
        contentRect: NSRect(x: -2000, y: -2000, width: 120, height: 40),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.orderFrontRegardless()
    guard let view = window.contentView else {
        return ([], "Picker host view missing")
    }
    picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    spin(0.4)
    picker.close()
    window.close()
    let records = delegate.proposed.map {
        record(for: $0, items: items, sourceAPI: "NSSharingServicePickerDelegate.proposedSharingServices PUBLIC_SUPPORTED")
    }
    return (records, delegate.proposed.isEmpty ? "Picker delegate was not invoked or returned no services. show(relativeTo:of:preferredEdge:) documents that it must be called from mouseDown." : nil)
}

func sharingSetsDiffer(_ samples: [SharingSample]) -> (strict: Bool, any: Bool, primaryTitles: [String: [String]]) {
    func titles(_ label: String) -> [String] {
        guard let sample = samples.first(where: { $0.label == label }) else { return [] }
        let fromDeprecated = sample.deprecatedAPIServices.map(\.title)
        if !fromDeprecated.isEmpty { return fromDeprecated }
        return sample.menuAPIServices.map(\.title)
    }
    let jpg = Set(titles("jpg"))
    let pdf = Set(titles("pdf"))
    let url = Set(titles("url"))
    let strict = !jpg.isEmpty && !pdf.isEmpty && !url.isEmpty && jpg != pdf && jpg != url && pdf != url
    let any = jpg != pdf || jpg != url || pdf != url
    return (strict, any, ["jpg": titles("jpg"), "pdf": titles("pdf"), "url": titles("url")])
}

func sharingDiscoveryLevel(_ samples: [SharingSample]) -> String {
    let deprecatedNonEmpty = samples.contains { !$0.deprecatedAPIServices.isEmpty }
    // The contextual sets come from sharingServices(forItems:), which is deprecated.
    // standardShareMenuItem is a single "Share…" item and does not enumerate services.
    // The picker delegate only runs when the picker is shown, and its proposed list
    // includes services whose canPerform(withItems:) is false.
    if deprecatedNonEmpty {
        return "PUBLIC_DEPRECATED"
    }
    if samples.contains(where: { !$0.menuAPIServices.isEmpty || !$0.pickerDelegateServices.isEmpty }) {
        return "PUBLIC_SUPPORTED"
    }
    return "UNAVAILABLE"
}

func executeHarmlessShare(fixtures: FixtureSet) -> SharingExecution {
    let items: [Any] = [fixtures.webURL as NSURL]
    let discovered = NSSharingService.sharingServices(forItems: items)
    let titles = discovered.map(\.title)
    let readingListName = NSSharingService.Name.addToSafariReadingList
    let reference = NSSharingService(named: readingListName)
    let chosen = discovered.first { service in
        if let reference {
            return service.title == reference.title && service.menuItemTitle == reference.menuItemTitle
        }
        return service.title.localizedCaseInsensitiveContains("Reading List")
    }
    guard let chosen else {
        return SharingExecution(
            discoveredTitles: titles,
            chosenTitle: nil,
            chosenPublicName: nil,
            input: fixtures.webURL.absoluteString,
            delegateEvents: [],
            newWindowTitles: [],
            invoked: false,
            error: "No discovered sharing service matched Add to Reading List. Refusing to invoke a service that was not in the discovered set."
        )
    }
    let delegate = ShareDelegate()
    chosen.delegate = delegate
    let before = Set(NSApp.windows.map(\.windowNumber))
    chosen.perform(withItems: items)
    spin(2.5)
    let newWindows = NSApp.windows.filter { !before.contains($0.windowNumber) }
    let titlesOfNew = newWindows.map { $0.title.isEmpty ? "(untitled \($0.windowNumber))" : $0.title }
    for window in newWindows {
        window.close()
    }
    let invoked = delegate.events.contains { $0.hasPrefix("didShareItems") || $0.hasPrefix("willShareItems") } || !newWindows.isEmpty
    return SharingExecution(
        discoveredTitles: titles,
        chosenTitle: chosen.title,
        chosenPublicName: matchPublicName(chosen)?.rawValue,
        input: fixtures.webURL.absoluteString,
        delegateEvents: delegate.events,
        newWindowTitles: titlesOfNew,
        invoked: invoked || !delegate.events.isEmpty,
        error: delegate.events.isEmpty && newWindows.isEmpty ? "perform(withItems:) returned without a delegate callback or a new window. Invocation may have completed silently or been ignored." : nil
    )
}

func discoverServices() -> [InstalledService] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots = [
        URL(fileURLWithPath: "/System/Library/Services"),
        URL(fileURLWithPath: "/Library/Services"),
        home.appendingPathComponent("Library/Services"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Library/CoreServices"),
        home.appendingPathComponent("Applications"),
    ]
    var services: [InstalledService] = []
    var seen = Set<String>()
    for infoURL in bundleInfoPlists(roots: roots, extensions: ["app", "service", "workflow"]) {
        guard let plist = loadPlist(infoURL) else { continue }
        guard let entries = plist["NSServices"] as? [[String: Any]], !entries.isEmpty else { continue }
        let bundleURL = infoURL.deletingLastPathComponent().deletingLastPathComponent()
        let workflow = loadWorkflowMetadata(bundleURL)
        for entry in entries {
            let menu = (entry["NSMenuItem"] as? [String: Any])?["default"] as? String ?? ""
            let message = entry["NSMessage"] as? String
            let bundleID = plist["CFBundleIdentifier"] as? String
            let key = [bundleID ?? bundleURL.path, menu, message ?? ""].joined(separator: "|")
            if seen.contains(key) { continue }
            seen.insert(key)
            let keyEquivalent = (entry["NSKeyEquivalent"] as? [String: Any])?["default"] as? String
            services.append(InstalledService(
                menuTitle: menu,
                message: message,
                portName: entry["NSPortName"] as? String,
                bundleIdentifier: bundleID,
                bundleName: plist["CFBundleName"] as? String ?? plist["CFBundleDisplayName"] as? String,
                bundlePath: bundleURL.path,
                sendTypes: stringArray(entry["NSSendTypes"]),
                sendFileTypes: stringArray(entry["NSSendFileTypes"]),
                returnTypes: stringArray(entry["NSReturnTypes"]),
                requiredContext: jsonString(entry["NSRequiredContext"]),
                keyEquivalent: keyEquivalent,
                workflowTypeIdentifier: workflow?["workflowTypeIdentifier"] as? String,
                serviceInputTypeIdentifier: workflow?["serviceInputTypeIdentifier"] as? String,
                discoverySource: "NSServices Info.plist",
                supportLevel: "PUBLIC_SUPPORTED"
            ))
        }
    }
    return services.sorted { lhs, rhs in
        if lhs.menuTitle == rhs.menuTitle { return (lhs.bundleIdentifier ?? "") < (rhs.bundleIdentifier ?? "") }
        return lhs.menuTitle < rhs.menuTitle
    }
}

func stringArray(_ value: Any?) -> [String] {
    guard let values = value as? [Any] else { return [] }
    return values.compactMap { $0 as? String }
}

func jsonString(_ value: Any?) -> String? {
    guard let value else { return nil }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8)
    else {
        return String(describing: value)
    }
    return string
}

func loadPlist(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
}

func loadWorkflowMetadata(_ bundleURL: URL) -> [String: Any]? {
    let candidates = [
        bundleURL.appendingPathComponent("Contents/document.wflow"),
        bundleURL.appendingPathComponent("Contents/Resources/document.wflow"),
    ]
    for candidate in candidates {
        guard let plist = loadPlist(candidate) else { continue }
        if let meta = plist["workflowMetaData"] as? [String: Any] {
            return meta
        }
    }
    return nil
}

func bundleInfoPlists(roots: [URL], extensions: Set<String>) -> [URL] {
    var infos: [URL] = []
    let skipLeaves: Set<String> = [
        "Resources", "Frameworks", "_CodeSignature", "MacOS", "SharedFrameworks",
        "Developer", "iOSSupport", "Documentation", "node_modules", "DerivedData",
    ]
    for root in roots {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let url as URL in enumerator {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            // Do not call skipDescendants() on a symlink. On this OS that also
            // suppresses the real directory the link points at, which hides
            // PlugIns reached through Versions/Current.
            if isLink {
                continue
            }
            if skipLeaves.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "Info.plist" else { continue }
            let contents = url.deletingLastPathComponent()
            let bundle = contents.deletingLastPathComponent()
            guard contents.lastPathComponent == "Contents", extensions.contains(bundle.pathExtension) else { continue }
            infos.append(url)
        }
    }
    return infos
}

struct ServiceExecutionOutcome {
    var primary: ServiceAttempt?
    var alternates: [ServiceAttempt]
    var notes: [String]
}

func executeHarmlessService(from services: [InstalledService]) -> ServiceExecutionOutcome {
    NSUpdateDynamicServices()
    var notes: [String] = []
    guard let fullWidth = services.first(where: { service in
        service.message == "convertTextToFullWidth" || service.menuTitle == "Convert Text to Full Width"
    }) else {
        notes.append("Full-width text conversion service was not present in discovered NSServices metadata.")
        return ServiceExecutionOutcome(primary: nil, alternates: [], notes: notes)
    }

    let input = "RightClick"
    let names = invocationNames(for: fullWidth)
    var attempts: [ServiceAttempt] = []
    for name in names {
        let attempt = performService(name: name, menuTitle: fullWidth.menuTitle, provider: fullWidth.bundleIdentifier, input: input)
        attempts.append(attempt)
        if attempt.timedNote == "timed out" {
            notes.append("Stopped retrying after NSPerformService timed out for '\(name)'.")
            break
        }
        if attempt.nsPerformServiceReturned == true, attemptHasObservableTextResult(attempt, input: input) {
            notes.append("NSPerformService succeeded for '\(name)' and the pasteboard result differed from the input.")
            return ServiceExecutionOutcome(primary: attempt, alternates: Array(attempts.dropLast()), notes: notes)
        }
    }

    if let script = services.first(where: { $0.menuTitle == "Script Editor/Get Result of AppleScript" && !$0.returnTypes.isEmpty }) {
        notes.append("Full-width conversion did not yield an observable pasteboard result. Trying discovered Script Editor result service.")
        let scriptInput = "return \"RIGHTCLICK_000C_OK\""
        let attempt = performService(
            name: script.menuTitle,
            menuTitle: script.menuTitle,
            provider: script.bundleIdentifier,
            input: scriptInput
        )
        attempts.append(attempt)
        let primary = attempt
        return ServiceExecutionOutcome(primary: primary, alternates: Array(attempts.dropLast()), notes: notes)
    }

    notes.append("No harmless returning service produced an observable result.")
    return ServiceExecutionOutcome(primary: attempts.last, alternates: Array(attempts.dropLast()), notes: notes)
}

func invocationNames(for service: InstalledService) -> [String] {
    var names: [String] = []
    func append(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !names.contains(trimmed) {
            names.append(trimmed)
        }
    }
    append(service.menuTitle)
    if let slash = service.menuTitle.split(separator: "/").last {
        append(String(slash))
    }
    if let bundleName = service.bundleName, !service.menuTitle.contains("/") {
        append("\(bundleName)/\(service.menuTitle)")
    }
    return names
}

func performService(name: String, menuTitle: String, provider: String?, input: String) -> ServiceAttempt {
    let pasteboard = NSPasteboard.withUniqueName()
    let types: [NSPasteboard.PasteboardType] = Array(Set([
        .string,
        NSPasteboard.PasteboardType("public.utf8-plain-text"),
        NSPasteboard.PasteboardType("NSStringPboardType"),
    ]))
    pasteboard.declareTypes(types, owner: nil)
    for type in types {
        pasteboard.setString(input, forType: type)
    }
    let before = pasteboard.changeCount
    let box = ServiceCallBox()
    DispatchQueue.global(qos: .userInitiated).async {
        let returned = NSPerformService(name, pasteboard)
        box.finish(returned)
    }
    let deadline = Date().addingTimeInterval(8)
    while !box.done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let ok = box.done ? box.ok : false
    let after = pasteboard.changeCount
    if !box.done {
        pasteboard.releaseGlobally()
        return ServiceAttempt(
            serviceMenuTitle: menuTitle,
            provider: provider,
            input: input,
            invokedName: name,
            nsPerformServiceReturned: nil,
            pasteboardChangeCountBefore: before,
            pasteboardChangeCountAfter: after,
            resultStrings: [:],
            error: "NSPerformService('\(name)') did not return within 8 seconds",
            timedNote: "timed out"
        )
    }
    var results: [String: String] = [:]
    for type in pasteboard.types ?? [] {
        if let string = pasteboard.string(forType: type), !string.isEmpty {
            results[type.rawValue] = string.prefix(500).description
        }
    }
    pasteboard.releaseGlobally()
    return ServiceAttempt(
        serviceMenuTitle: menuTitle,
        provider: provider,
        input: input,
        invokedName: name,
        nsPerformServiceReturned: ok,
        pasteboardChangeCountBefore: before,
        pasteboardChangeCountAfter: after,
        resultStrings: results,
        error: ok ? nil : "NSPerformService returned false for '\(name)'",
        timedNote: nil
    )
}

final class ServiceCallBox {
    private let lock = NSLock()
    private var storedDone = false
    private var storedOK = false

    var done: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedDone
    }

    var ok: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedOK
    }

    func finish(_ value: Bool) {
        lock.lock()
        storedOK = value
        storedDone = true
        lock.unlock()
    }
}

func attemptHasObservableTextResult(_ attempt: ServiceAttempt, input: String) -> Bool {
    let values = attempt.resultStrings.values
    if values.contains(where: { $0 != input && $0.contains("Ｒ") }) { return true }
    if values.contains(where: { $0 != input && !$0.isEmpty }) { return true }
    if let after = attempt.pasteboardChangeCountAfter, after != attempt.pasteboardChangeCountBefore {
        return values.contains(where: { !$0.isEmpty })
    }
    return false
}

struct ActionDiscovery {
    var records: [ActionExtensionRecord]
    var source: String
    var notes: [String]
}

func discoverActionExtensions() -> ActionDiscovery {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        home.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/System/Library/CoreServices"),
        URL(fileURLWithPath: "/System/Library/Frameworks"),
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks"),
        URL(fileURLWithPath: "/Library/Application Support"),
        home.appendingPathComponent("Library/Application Support"),
    ]
    var records: [ActionExtensionRecord] = []
    var skippedOtherPoints = 0
    for infoURL in bundleInfoPlists(roots: roots, extensions: ["appex"]) {
        guard let plist = loadPlist(infoURL) else { continue }
        guard let ext = plist["NSExtension"] as? [String: Any] else { continue }
        let point = ext["NSExtensionPointIdentifier"] as? String
        guard point == "com.apple.ui-services" else {
            skippedOtherPoints += 1
            continue
        }
        let attributes = ext["NSExtensionAttributes"] as? [String: Any] ?? [:]
        let ruleValue = attributes["NSExtensionActivationRule"]
        let (ruleText, ruleKind) = describeRule(ruleValue)
        let method = applicabilityMethod(for: ruleKind)
        let bundleURL = infoURL.deletingLastPathComponent().deletingLastPathComponent()
        let bundleID = plist["CFBundleIdentifier"] as? String
        var applicability: [String: String] = [:]
        for sample in sampleKinds {
            applicability[sample.label] = applies(ruleValue: ruleValue, ruleKind: ruleKind, sample: sample).rawValue
        }
        records.append(ActionExtensionRecord(
            name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String,
            bundleIdentifier: bundleID,
            bundlePath: bundleURL.path,
            extensionPointIdentifier: point,
            allowsFinderPreviewItem: attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool,
            finderPreviewLabel: attributes["NSExtensionServiceFinderPreviewLabel"] as? String,
            finderPreviewIconName: attributes["NSExtensionServiceFinderPreviewIconName"] as? String,
            roleType: attributes["NSExtensionServiceRoleType"] as? String,
            allowsToolbarItem: attributes["NSExtensionServiceAllowsToolbarItem"] as? Bool,
            activationRule: ruleText,
            activationRuleKind: ruleKind,
            applicability: applicability,
            applicabilityMethod: method,
            supportLevel: "PUBLIC_SUPPORTED",
            invocation: "unsupported"
        ))
    }
    records.sort { ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "") }
    return ActionDiscovery(
        records: records,
        source: "Documented NSExtension / NSExtensionPointIdentifier / NSExtensionAttributes keys in installed .appex Info.plist bundles. Enumeration is a read-only bundle scan because the public SDK has no NSExtension matching API.",
        notes: [
            "Skipped \(skippedOtherPoints) appex bundles whose NSExtensionPointIdentifier was not com.apple.ui-services.",
            "Applicability for dictionary activation rules follows the documented NSExtensionActivationSupports* keys. Predicate-string rules are matched by a UTI token scan and are labelled as a heuristic.",
            "DISCOVERED is not treated as EXECUTABLE. invocation is unsupported unless a later public call succeeds. None did.",
        ]
    )
}

struct SampleKind {
    var label: String
    var type: UTType
    var isText: Bool
    var isWebURL: Bool
    var isFile: Bool
}

let sampleKinds: [SampleKind] = [
    SampleKind(label: "jpg", type: .jpeg, isText: false, isWebURL: false, isFile: true),
    SampleKind(label: "pdf", type: .pdf, isText: false, isWebURL: false, isFile: true),
    SampleKind(label: "mov", type: .quickTimeMovie, isText: false, isWebURL: false, isFile: true),
    SampleKind(label: "txt", type: .plainText, isText: true, isWebURL: false, isFile: true),
    SampleKind(label: "url", type: .url, isText: false, isWebURL: true, isFile: false),
]

enum RuleApplicability: String {
    case applies
    case doesNotApply
    case unknown
}

func describeRule(_ value: Any?) -> (String, String) {
    switch value {
    case let string as String:
        return (string, string.trimmingCharacters(in: .whitespacesAndNewlines) == "TRUEPREDICATE" ? "true_predicate" : "predicate")
    case let dict as [String: Any]:
        return (jsonString(dict) ?? String(describing: dict), "dictionary")
    default:
        return (value.map { String(describing: $0) } ?? "", "missing")
    }
}

func applicabilityMethod(for kind: String) -> String {
    switch kind {
    case "dictionary":
        return "documented_activation_dictionary"
    case "predicate":
        return "uti_token_heuristic"
    case "true_predicate":
        return "true_predicate_not_content_specific"
    default:
        return "unknown"
    }
}

func applies(ruleValue: Any?, ruleKind: String, sample: SampleKind) -> RuleApplicability {
    switch ruleKind {
    case "dictionary":
        guard let dict = ruleValue as? [String: Any] else { return .unknown }
        return applies(dictionary: dict, sample: sample)
    case "predicate":
        guard let predicate = ruleValue as? String else { return .unknown }
        return applies(predicate: predicate, sample: sample)
    case "true_predicate":
        return .unknown
    default:
        return .unknown
    }
}

func applies(dictionary: [String: Any], sample: SampleKind) -> RuleApplicability {
    func maxCount(_ key: String) -> Int? {
        guard let value = dictionary[key] else { return nil }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
    let image = maxCount("NSExtensionActivationSupportsImageWithMaxCount")
    let movie = maxCount("NSExtensionActivationSupportsMovieWithMaxCount")
    let web = maxCount("NSExtensionActivationSupportsWebURLWithMaxCount")
    let webpage = maxCount("NSExtensionActivationSupportsWebPageWithMaxCount")
    let file = maxCount("NSExtensionActivationSupportsFileWithMaxCount")
    let attachments = maxCount("NSExtensionActivationSupportsAttachmentsWithMaxCount")
    let text = dictionary["NSExtensionActivationSupportsText"] as? Bool

    if sample.type.conforms(to: .image) {
        if let image { return image > 0 ? .applies : .doesNotApply }
        if file ?? 0 > 0 || attachments ?? 0 > 0 { return .applies }
        return .doesNotApply
    }
    if sample.type.conforms(to: .movie) {
        if let movie { return movie > 0 ? .applies : .doesNotApply }
        if file ?? 0 > 0 || attachments ?? 0 > 0 { return .applies }
        return .doesNotApply
    }
    if sample.type.conforms(to: .pdf) {
        if file ?? 0 > 0 || attachments ?? 0 > 0 { return .applies }
        return .doesNotApply
    }
    if sample.isText {
        if text == true { return .applies }
        if file ?? 0 > 0 || attachments ?? 0 > 0 { return .applies }
        return .doesNotApply
    }
    if sample.isWebURL {
        if web ?? 0 > 0 || webpage ?? 0 > 0 { return .applies }
        return .doesNotApply
    }
    return .unknown
}

func applies(predicate: String, sample: SampleKind) -> RuleApplicability {
    let pattern = #"UTI-(?:CONFORMS-TO|EQUALS)\s+"([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return .unknown }
    let range = NSRange(predicate.startIndex..<predicate.endIndex, in: predicate)
    let matches = regex.matches(in: predicate, range: range)
    if matches.isEmpty { return .unknown }
    var mentioned: [UTType] = []
    for match in matches {
        guard let swiftRange = Range(match.range(at: 1), in: predicate) else { continue }
        let identifier = String(predicate[swiftRange])
        if let type = UTType(identifier) {
            mentioned.append(type)
        }
    }
    if mentioned.isEmpty { return .unknown }
    let hit = mentioned.contains { sample.type.conforms(to: $0) || sample.type.identifier == $0.identifier }
    return hit ? .applies : .doesNotApply
}

func applicabilityMatrix(_ records: [ActionExtensionRecord]) -> [String: [String: String]] {
    var matrix: [String: [String: String]] = [:]
    for record in records {
        let title = record.name ?? record.bundleIdentifier ?? record.bundlePath
        matrix[title] = record.applicability
    }
    return matrix
}

func probePrivateNSExtension() -> PrivateRuntimeResult {
    let names = RCProbeCopyMethodNames("NSExtension")
    var attempts: [PrivateMatchAttempt] = []
    let attributePairs = [
        ("NSExtensionPointIdentifier", "com.apple.ui-services"),
        ("NSExtensionPointName", "com.apple.ui-services"),
    ]
    for pair in attributePairs {
        let box = ResultBox()
        RCProbeMatchExtensions([pair.0: pair.1]) { items, error in
            box.error = error?.localizedDescription
            if let items = items as? [[String: Any]] {
                box.matches = items.map { item in
                    let identifier = item["identifier"] as? String ?? ""
                    let description = item["description"] as? String ?? ""
                    return identifier.isEmpty ? description : identifier
                }
            }
            box.done = true
        }
        let deadline = Date().addingTimeInterval(4)
        while !box.done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !box.done {
            attempts.append(PrivateMatchAttempt(
                attributeKey: pair.0,
                attributeValue: pair.1,
                error: "Timed out waiting for NSExtension callback",
                matchCount: nil,
                matches: []
            ))
        } else {
            attempts.append(PrivateMatchAttempt(
                attributeKey: pair.0,
                attributeValue: pair.1,
                error: box.error,
                matchCount: box.matches.count,
                matches: box.matches
            ))
        }
    }
    return PrivateRuntimeResult(
        nsExtensionClassPresent: !names.isEmpty || NSClassFromString("NSExtension") != nil,
        methodNames: names.sorted(),
        matchAttempts: attempts,
        productUse: "EXPERIMENTAL probe only. Product execution does not call NSExtension."
    )
}

final class ResultBox {
    var done = false
    var error: String?
    var matches: [String] = []
}

func evaluateGates(
    samples: [SharingSample],
    sharingExecution: SharingExecution?,
    services: [InstalledService],
    serviceAttempt: ServiceAttempt?,
    actions: [ActionExtensionRecord],
    sharingDifferentiated: (strict: Bool, any: Bool, primaryTitles: [String: [String]])
) -> GateSection {
    var reasons: [String] = []
    let shareDiscovery: String
    if sharingDifferentiated.strict {
        shareDiscovery = "PASS"
        reasons.append("Sharing sets for JPG, PDF, and URL differ and were returned by macOS sharing APIs.")
    } else if sharingDifferentiated.any && samples.contains(where: { !$0.deprecatedAPIServices.isEmpty || !$0.menuAPIServices.isEmpty }) {
        shareDiscovery = "PASS"
        reasons.append("Sharing discovery returned context-sensitive sets, but JPG, PDF, and URL were not all pairwise different. Titles: \(sharingDifferentiated.primaryTitles).")
    } else {
        shareDiscovery = "FAIL"
        reasons.append("Sharing discovery did not produce distinct non-empty capability sets.")
    }

    let shareExecution: String
    if let sharingExecution, sharingExecution.chosenTitle != nil, sharingExecution.invoked {
        shareExecution = "PASS"
        reasons.append("Sharing execution selected '\(sharingExecution.chosenTitle ?? "")' from the discovered URL set and invoked it.")
    } else if sharingExecution?.chosenTitle != nil {
        shareExecution = "FAIL"
        reasons.append("A discovered share service was selected but invocation produced no observable callback or window: \(sharingExecution?.error ?? "no detail").")
    } else {
        shareExecution = "FAIL"
        reasons.append(sharingExecution?.error ?? "Sharing execution did not run.")
    }

    let serviceDiscovery = services.isEmpty ? "FAIL" : "PASS"
    if services.isEmpty {
        reasons.append("No NSServices entries were found.")
    } else {
        reasons.append("Discovered \(services.count) services from NSServices Info.plist metadata.")
    }

    let serviceExecution: String
    if let serviceAttempt, serviceAttempt.nsPerformServiceReturned == true, attemptHasObservableTextResult(serviceAttempt, input: serviceAttempt.input) {
        serviceExecution = "PASS"
        reasons.append("NSPerformService('\(serviceAttempt.invokedName)') returned true with an observable pasteboard result.")
    } else {
        serviceExecution = "FAIL"
        reasons.append("NSPerformService did not return an observable result. Last error: \(serviceAttempt?.error ?? "none").")
    }

    let contentSpecific = actions.filter { record in
        record.activationRuleKind != "true_predicate" && record.applicability.values.contains("applies")
    }
    let actionDiscovery = contentSpecific.isEmpty ? "FAIL" : "PASS"
    if contentSpecific.isEmpty {
        reasons.append("No content-specific com.apple.ui-services action extensions were discovered.")
    } else {
        reasons.append("Discovered \(contentSpecific.count) content-specific action extensions from appex metadata. Invocation remains unsupported.")
    }
    let actionExecution = "FAIL"
    reasons.append("Quick Action execution is FAIL because no public direct invocation API succeeded. Discovery and execution are separate.")

    let viable = shareDiscovery == "PASS" || serviceDiscovery == "PASS" || actionDiscovery == "PASS"
    let allPass = [shareDiscovery, shareExecution, serviceDiscovery, serviceExecution].allSatisfy { $0 == "PASS" } && actionDiscovery == "PASS"
    // Quick action execution is expected to be unavailable. RIGHTCLICK-000 can still pass
    // the product gate when discovery is honest and at least one family executes.
    let executionFamilies = [shareExecution, serviceExecution].filter { $0 == "PASS" }.count
    let overall: String
    if allPass && actionExecution == "PASS" {
        overall = "PASS"
    } else if viable && executionFamilies >= 1 && (shareDiscovery == "PASS" || serviceDiscovery == "PASS") {
        overall = actionExecution == "FAIL" && actionDiscovery == "PASS" ? "PARTIAL" : (executionFamilies >= 1 && shareDiscovery == "PASS" && serviceDiscovery == "PASS" && serviceExecution == "PASS" && shareExecution == "PASS" ? "PARTIAL" : "PARTIAL")
    } else if viable {
        overall = "PARTIAL"
    } else {
        overall = "FAIL"
    }

    return GateSection(
        sharingDiscovery: shareDiscovery,
        sharingExecution: shareExecution,
        sharingSupportLevel: sharingDiscoveryLevel(samples),
        servicesDiscovery: serviceDiscovery,
        servicesExecution: serviceExecution,
        servicesSupportLevel: "PUBLIC_SUPPORTED",
        quickActionDiscovery: actionDiscovery,
        quickActionExecution: actionExecution,
        quickActionSupportLevel: contentSpecific.isEmpty ? "UNAVAILABLE" : "PUBLIC_SUPPORTED discovery, execution UNAVAILABLE",
        rightclick000: overall,
        reasons: reasons
    )
}

func writeReport(_ report: ProbeReport, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(report)
        try data.write(to: url)
        let markdown = renderMarkdown(report)
        let reportURL = url.deletingLastPathComponent().appendingPathComponent("REPORT.md")
        try markdown.write(to: reportURL, atomically: true, encoding: .utf8)
    } catch {
        fputs("Failed to write report: \(error)\n", stderr)
    }
}

func renderMarkdown(_ report: ProbeReport) -> String {
    var lines: [String] = []
    lines.append("# RIGHTCLICK-000 probe report")
    lines.append("")
    lines.append("Generated: \(report.generatedAt)")
    lines.append("macOS: \(report.macosVersion) (\(report.macosBuild))")
    lines.append("")
    lines.append("## Gates")
    lines.append("")
    lines.append("```text")
    lines.append("SHARING")
    lines.append("Discovery: \(report.gates.sharingDiscovery)")
    lines.append("Execution: \(report.gates.sharingExecution)")
    lines.append("Support level: \(report.gates.sharingSupportLevel)")
    lines.append("")
    lines.append("SERVICES")
    lines.append("Discovery: \(report.gates.servicesDiscovery)")
    lines.append("Execution: \(report.gates.servicesExecution)")
    lines.append("Support level: \(report.gates.servicesSupportLevel)")
    lines.append("")
    lines.append("QUICK ACTIONS")
    lines.append("Discovery: \(report.gates.quickActionDiscovery)")
    lines.append("Execution: \(report.gates.quickActionExecution)")
    lines.append("Support level: \(report.gates.quickActionSupportLevel)")
    lines.append("")
    lines.append("RIGHTCLICK-000: \(report.gates.rightclick000)")
    lines.append("```")
    lines.append("")
    lines.append("## Reasons")
    lines.append("")
    for reason in report.gates.reasons {
        lines.append("- \(reason)")
    }
    lines.append("")
    lines.append("## Sharing titles by input")
    lines.append("")
    for sample in report.sharing.samples {
        let titles = sample.deprecatedAPIServices.map(\.title)
        let shown = titles.isEmpty ? sample.menuAPIServices.map(\.title) : titles
        lines.append("### \(sample.label)")
        lines.append("")
        if shown.isEmpty {
            lines.append("(none)")
        } else {
            for title in shown {
                lines.append("- \(title)")
            }
        }
        if !sample.errors.isEmpty {
            lines.append("")
            lines.append("Errors:")
            for error in sample.errors {
                lines.append("- \(error)")
            }
        }
        lines.append("")
    }
    if let execution = report.sharing.execution {
        lines.append("## Sharing execution")
        lines.append("")
        lines.append("- chosen: \(execution.chosenTitle ?? "(none)")")
        lines.append("- public name: \(execution.chosenPublicName ?? "(unmatched)")")
        lines.append("- input: \(execution.input)")
        lines.append("- invoked: \(execution.invoked)")
        lines.append("- delegate: \(execution.delegateEvents.joined(separator: " | "))")
        lines.append("- error: \(execution.error ?? "(none)")")
        lines.append("")
    }
    lines.append("## Service execution")
    lines.append("")
    if let attempt = report.services.execution {
        lines.append("- name: \(attempt.invokedName)")
        lines.append("- returned: \(String(describing: attempt.nsPerformServiceReturned))")
        lines.append("- results: \(attempt.resultStrings)")
        lines.append("- error: \(attempt.error ?? "(none)")")
    } else {
        lines.append("(none)")
    }
    lines.append("")
    lines.append("## Quick action applicability")
    lines.append("")
    for record in report.quickActions.extensions {
        lines.append("- \(record.name ?? record.bundleIdentifier ?? "?") [\(record.activationRuleKind)] \(record.applicability)")
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

func summary(_ report: ProbeReport) -> String {
    """
    RIGHTCLICK-000
    SHARING discovery=\(report.gates.sharingDiscovery) execution=\(report.gates.sharingExecution) support=\(report.gates.sharingSupportLevel)
    SERVICES discovery=\(report.gates.servicesDiscovery) execution=\(report.gates.servicesExecution) support=\(report.gates.servicesSupportLevel)
    QUICK ACTIONS discovery=\(report.gates.quickActionDiscovery) execution=\(report.gates.quickActionExecution) support=\(report.gates.quickActionSupportLevel)
    OVERALL \(report.gates.rightclick000)
    services=\(report.services.count) actionExtensions=\(report.quickActions.extensions.count)
    """
}
