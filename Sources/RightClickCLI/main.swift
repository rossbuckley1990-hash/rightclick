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
            return emit(RightClickMCPRuntime.makeEngine().doctor(), json: json)
        case "inspect":
            return inspect(positional, json: json)
        case "actions", "capabilities":
            return capabilities(positional, json: json)
        case "describe", "explain":
            return describe(positional, json: json)
        case "run":
            return runCapability(rest, positional: positional, json: json)
        case "status":
            return status(positional, json: json)
        case "providers":
            return providers(json: json)
        case "provider":
            return RightClickProviderCLI.run(rest)
        case "authority":
            return RightClickAuthorityCLI.run(rest)
        case "refresh":
            RightClickMCPRuntime.makeEngine().refresh()
            print("Refreshed macOS Services registrations. The next query scans installed providers again.")
            return 0
        case "version", "--version":
            print(RightClickVersion.current)
            return 0
        case "setup":
            do {
                if rest.first == "chatgpt" {
                    return RightClickChatGPTOnboarding.run(
                        args: rest,
                        executable: RightClickSetup.executablePath()
                    )
                }

                if try RightClickLocalOnboarding.bridgeArguments(rest) {
                    return RightClickSetup.run(args: rest, json: json)
                }
                return RightClickLocalOnboarding.run(
                    args: rest,
                    executable: RightClickSetup.executablePath()
                ) {
                    let item = try RightClickMCPRuntime.makeEngine().inspect("RIGHTCLICK onboarding probe")
                    guard item.typeIdentifier == "public.plain-text" else {
                        throw RightClickLocalOnboarding.SetupError(
                            "Local text inspection did not return public.plain-text."
                        )
                    }
                    return "PASS: local text inspection; not an MCP connection test"
                }
            } catch {
                if json {
                    print(RightClickJSON.encode([
                        "status": "FAILED",
                        "error": String(describing: error),
                        "mcpConnection": "NOT_VERIFIED",
                        "outcomeVerification": "NOT_RUN",
                    ]))
                } else {
                    fputs("Setup failed: \(error)\n", stderr)
                }
                return 2
            }
        case "bridge":
            return RightClickBridgeCLI.run(rest)
        case "auth":
            return RightClickAuth.run(positional)
        case "serve":
            return RightClickServe.run(rest)
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
            let item = try RightClickMCPRuntime.makeEngine().inspect(raw)
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
            let result = try RightClickMCPRuntime.makeEngine().capabilities(for: raw)
            if json {
                print(RightClickJSON.encode(ActionList(item: result.item, actions: result.capabilities)))
                return 0
            }
            print(CLIRender.renderCapabilities(item: result.item, capabilities: result.capabilities))
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
            let capability = try RightClickMCPRuntime.makeEngine().describe(id: id, item: item)
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

        let verification: VerificationSpec?

        if let raw = flag(args, "--verify-json") {
            guard let data = raw.data(using: .utf8) else {
                fputs("Invalid --verify-json: value is not UTF-8.\n", stderr)
                return 2
            }

            do {
                verification = try JSONDecoder().decode(
                    VerificationSpec.self,
                    from: data
                )
            } catch {
                fputs(
                    "Invalid --verify-json VerificationSpec: \(error)\n",
                    stderr
                )
                return 2
            }
        } else {
            verification = nil
        }

        do {
            let result = try RightClickMCPRuntime.makeEngine().run(
                id: resolvedAction,
                item: resolvedItem,
                confirmed: confirmed,
                expectedOutput: flag(args, "--expect-output"),
                verification: verification
            )
            if json {
                print(RightClickJSON.encode(result))
            } else {
                print(CLIRender.renderRun(result))
            }
            switch result.status {
            case .accepted, .verified: return 0
            case .confirmationRequired: return 3
            case .unsupported: return 4
            case .unavailable: return 4
            case .rejected: return 1
            case .failed: return 1
            case .unknown: return 1
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
            print(CLIRender.renderDoctor(report))
        } else if let item = value as? ContentItem {
            print(CLIRender.renderItem(item))
        } else {
            print(RightClickJSON.encode(value))
        }
        return 0
    }

    private func flag(_ args: [String], _ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func status(_ positional: [String], json: Bool) -> Int {
        guard let id = positional.first else {
            fputs("status needs an execution id.\n", stderr)
            return 2
        }
        let record = RightClickMCPRuntime.makeEngine().executionStatus(id)
        if json {
            print(RightClickJSON.encode(record))
        } else {
            print(record.state.rawValue)
            print(record.message)
            for event in record.events {
                print("  \(event)")
            }
        }
        return record.state == .unknown && record.actionId.isEmpty ? 1 : 0
    }

    private func providers(json: Bool) -> Int {
        let rows = RightClickMCPRuntime.makeEngine().providers()
        if json {
            print(RightClickJSON.encode(rows))
            return 0
        }
        var lines = ["Provider                     Capabilities", String(repeating: "─", count: 42)]
        for row in rows {
            let name = row.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            lines.append("\(name) \(row.capabilityTitles.count)")
        }
        print(lines.joined(separator: "\n"))
        return 0
    }

    private func usage() -> String {
        """
        RIGHTCLICK
        Give your AI the capabilities already installed on your Mac.

        rightclick doctor
        rightclick inspect <item>
        rightclick actions <item>
        rightclick run <action-id> <item> [--yes] [--expect-output <exact-text>] [--verify-json <VerificationSpec JSON>]
        rightclick status <execution-id>
        rightclick providers
        rightclick provider list [--json]
        rightclick provider add --id <id> --spec-url <https-url> --base-url <https-url> [--auth-scheme <scheme>]
        rightclick provider remove --id <id>
        rightclick authority set --origin <https-origin> --scheme <name>
        rightclick authority status --origin <https-origin> --scheme <name>
        rightclick authority delete --origin <https-origin> --scheme <name>
        rightclick refresh
        rightclick setup [--client cursor] [--yes] [--dry-run]
        rightclick setup --client cursor --disconnect [--yes] [--dry-run]
        rightclick setup --chatgpt-tunnel-id tunnel_...  (explicit legacy bridge preparation)
        rightclick bridge run
        rightclick bridge activate|status|deactivate
        rightclick bridge key set|status|delete
        rightclick serve [--tunnel] [--port 8765]
        rightclick auth rotate
        rightclick mcp
        rightclick version

        --json prints machine-readable output.
        --verify-json supplies provider-independent semantic postconditions.
        """
    }
}

private enum CLIRender {
static func renderItem(_ item: ContentItem) -> String {
    """
    \(item.display)

    kind            \(item.kind)
    type            \(item.typeIdentifier ?? "unknown")
    description     \(item.typeDescription ?? "")
    size            \(item.byteCount.map(String.init) ?? "n/a")
    """
}

static func renderDoctor(_ report: DoctorReport) -> String {
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

static func renderCapabilities(item: ContentItem, capabilities: [Capability]) -> String {
    let name = URL(fileURLWithPath: item.display).lastPathComponent
    var lines = [
        "RIGHTCLICK",
        item.path == nil ? item.display : name,
        "\(item.typeDescription ?? item.kind) · \(item.typeIdentifier ?? "unknown")",
        "",
        "AVAILABLE ACTIONS",
        "",
    ]
    let groups: [(String, CapabilitySource)] = [
        ("LOCAL", .service),
        ("SHARE", .sharingService),
        ("EXTENSIONS", .actionExtension),
    ]
    var shown = 0
    for (title, source) in groups {
        let rows = capabilities.filter { $0.source == source }
        if rows.isEmpty { continue }
        lines.append(title)
        for row in rows {
            lines.append("  \(row.title)")
            shown += 1
        }
        lines.append("")
    }
    if shown == 0 {
        lines.append("No applicable capabilities were discovered.")
        lines.append("")
    }
    let providers = Set(capabilities.compactMap { $0.provider?.bundleIdentifier ?? $0.provider?.name }).count
    lines.append("\(shown) capabilities from \(providers) providers")
    return lines.joined(separator: "\n")
}

static func renderRun(_ result: RunResult) -> String {
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
}
