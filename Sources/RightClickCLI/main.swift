import Foundation
import RightClickCore
import RightClickMCP

@main
struct RightClickCLIMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let code = CLI().run(args)
        if code != 0 {
            exit(Int32(code))
        }
    }
}

struct CLI {
    func run(_ args: [String]) -> Int {
        guard let command = args.first else {
            print(usage())
            return 0
        }
        let rest = Array(args.dropFirst())
        let json = rest.contains("--json")
        let positional = rest.filter { !$0.hasPrefix("--") }
        switch command {
        case "help", "--help", "-h":
            print(usage())
            return 0
        case "doctor":
            return emit(CapabilityEngine().doctor(), json: json)
        case "inspect":
            return inspect(positional, json: json)
        case "capabilities":
            return capabilities(positional, json: json)
        case "describe":
            return describe(positional, json: json)
        case "run":
            return runCapability(rest, positional: positional, json: json)
        case "providers":
            return emit(CapabilityEngine().providers(), json: json || true)
        case "mcp":
            return RightClickMCPMain.run(Array(args.dropFirst()))
        default:
            fputs("Unknown command: \(command)\n\n\(usage())\n", stderr)
            return 2
        }
    }

    private func inspect(_ positional: [String], json: Bool) -> Int {
        guard let raw = positional.first else {
            fputs("inspect needs an item.\n", stderr)
            return 2
        }
        do {
            let item = try CapabilityEngine().inspect(raw)
            return emit(item, json: json)
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    private func capabilities(_ positional: [String], json: Bool) -> Int {
        guard let raw = positional.first else {
            fputs("capabilities needs an item.\n", stderr)
            return 2
        }
        do {
            let result = try CapabilityEngine().capabilities(for: raw)
            if json {
                let payload = CapabilityList(item: result.item, actions: result.capabilities)
                print(RightClickJSON.encode(payload))
                return 0
            }
            print(renderCapabilities(item: result.item, capabilities: result.capabilities))
            return 0
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    private func describe(_ positional: [String], json: Bool) -> Int {
        guard let id = positional.first else {
            fputs("describe needs a capability id.\n", stderr)
            return 2
        }
        let item = positional.dropFirst().first
        do {
            let capability = try CapabilityEngine().describe(id: id, item: item)
            return emit(capability, json: json || true)
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    private func runCapability(_ args: [String], positional: [String], json: Bool) -> Int {
        let confirmed = args.contains("--yes") || args.contains("--confirmed")
        let itemFlag = flag(args, "--item")
        let actionFlag = flag(args, "--action") ?? flag(args, "--id")
        let item = itemFlag ?? positional.dropFirst().first ?? positional.first
        let action = actionFlag ?? positional.first
        guard let action, let item, action != item || itemFlag != nil else {
            fputs("run needs a capability and an item.\n\(usage())\n", stderr)
            return 2
        }
        let resolvedItem = itemFlag ?? (positional.count >= 2 ? positional[1] : item)
        let resolvedAction = actionFlag ?? positional[0]
        do {
            let result = try CapabilityEngine().run(id: resolvedAction, item: resolvedItem, confirmed: confirmed)
            if json {
                print(RightClickJSON.encode(result))
            } else {
                print(renderRun(result))
            }
            switch result.status {
            case .executed: return 0
            case .confirmationRequired: return 3
            case .unsupported: return 4
            case .failed: return 1
            }
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    private func emit<T: Encodable>(_ value: T, json: Bool) -> Int {
        if json {
            print(RightClickJSON.encode(value))
        } else if let report = value as? DoctorReport {
            print(renderDoctor(report))
        } else if let item = value as? ContentItem {
            print(renderItem(item))
        } else {
            print(RightClickJSON.encode(value))
        }
        return 0
    }

    private func flag(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func usage() -> String {
        """
        RIGHTCLICK MCP
        If you can right-click it, your AI can do it.

        Usage:
          rightclick-mcp doctor
          rightclick-mcp inspect <item>
          rightclick-mcp capabilities <item>
          rightclick-mcp describe <capability-id> [item]
          rightclick-mcp run <capability-id> <item> [--yes]
          rightclick-mcp run --item <item> --action <capability-id-or-title> [--yes]
          rightclick-mcp providers
          rightclick-mcp mcp
          rightclick-mcp mcp --http --port 8765 --token <bearer>

        Add --json for machine-readable output.
        Items may be file paths, http(s) URLs, or plain text.
        """
    }
}

private struct CapabilityList: Codable {
    var item: ContentItem
    var actions: [Capability]
}

private func renderItem(_ item: ContentItem) -> String {
    """
    \(item.display)

    kind            \(item.kind)
    type            \(item.typeIdentifier ?? "unknown")
    description     \(item.typeDescription ?? "")
    size            \(item.byteCount.map(String.init) ?? "n/a")
    """
}

private func renderDoctor(_ report: DoctorReport) -> String {
    """
    RIGHTCLICK doctor
    macOS \(report.macosVersion) (\(report.macosBuild))

    SHARING
      discovery     \(report.sharingDiscovery)
      execution     \(report.sharingExecution)
      support       \(report.sharingSupportLevel)

    SERVICES
      discovery     \(report.servicesDiscovery)
      execution     \(report.servicesExecution)
      support       \(report.servicesSupportLevel)
      registrations \(report.serviceRegistrationCount)

    QUICK ACTIONS
      discovery     \(report.quickActionDiscovery)
      execution     \(report.quickActionExecution)
      support       \(report.quickActionSupportLevel)
      extensions    \(report.actionExtensionCount)

    \(report.notes.map { "• \($0)" }.joined(separator: "\n"))
    """
}

private func renderCapabilities(item: ContentItem, capabilities: [Capability]) -> String {
    var lines: [String] = []
    lines.append(item.display)
    lines.append("\(item.kind)  ·  \(item.typeIdentifier ?? "unknown")")
    lines.append("")
    let groups: [(String, CapabilitySource)] = [
        ("SHARING", .sharingService),
        ("SERVICES", .service),
        ("QUICK ACTIONS", .actionExtension),
    ]
    var any = false
    for (title, source) in groups {
        let rows = capabilities.filter { $0.source == source }
        if rows.isEmpty { continue }
        any = true
        lines.append(title)
        lines.append(String(repeating: "─", count: 44))
        for row in rows {
            let gate = row.requiresConfirmation ? "confirmation" : "allowed"
            let invoke = row.invocation == .unsupported ? "not invokable" : row.invocation.rawValue
            lines.append("  \(row.title)")
            lines.append("    \(row.id)")
            lines.append("    \(row.safety.rawValue) · \(invoke) · \(gate) · \(row.supportLevel.rawValue)")
        }
        lines.append("")
    }
    if !any {
        lines.append("No applicable capabilities were discovered.")
    }
    return lines.joined(separator: "\n")
}

private func renderRun(_ result: RunResult) -> String {
    var lines = [
        result.status.rawValue,
        result.title ?? result.actionID,
        result.message,
    ]
    if let output = result.output, !output.isEmpty {
        lines.append("")
        lines.append(output)
    }
    return lines.joined(separator: "\n")
}
