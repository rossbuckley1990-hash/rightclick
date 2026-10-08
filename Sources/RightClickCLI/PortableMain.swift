#if !os(macOS)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif
import RightClickCore
import RightClickMCP

/// Host composition only: every generic command uses the original engine.
@main
struct RightClickPortableMain {
    static func main() { exit(Int32(run(Array(CommandLine.arguments.dropFirst())))) }
    static func run(_ args: [String]) -> Int {
        let command = args.first ?? "help"
        let rest = Array(args.dropFirst())
        if command == "mcp" || command == "serve" { return RightClickMCPMain.run(rest) }
        if command == "provider" { return RightClickProviderCLI.run(rest) }
        if command == "version" || command == "--version" { print(RightClickVersion.current); return 0 }
        if ["help", "--help", "-h"].contains(command) {
            print("""
            RIGHTCLICK portable capability runtime
              rightclick serve                       Seven-operation MCP over stdio
              rightclick serve --http --port 8765     Loopback HTTP; requires RIGHTCLICK_MCP_TOKEN
              rightclick doctor --json
              rightclick inspect ITEM --json
              rightclick actions ITEM --json
              rightclick explain ACTION_ID ITEM --json
              rightclick run ACTION_ID ITEM [--arguments JSON] [--expect-output TEXT] [--verify-json JSON] [--yes]
              rightclick status EXECUTION_ID --json
              rightclick providers --json
              rightclick provider ...                Configured provider registry

            Native desktop capabilities require their host adapter. Headless hosts
            use portable providers and explicit origin-bound environment authority.
            Discovery is not approval; provider acceptance is not verification.
            """)
            return 0
        }
        do {
            let engine = RightClickMCPRuntime.makeEngine(startBrowsing: false)
            if command == "doctor" {
                guard rest.allSatisfy({ $0 == "--json" }) else { throw RightClickError("doctor accepts --json.") }
                print(RightClickJSON.encode(engine.doctor())); return 0
            }
            var positional: [String] = []; var arguments: CapabilityArguments?
            var expected: String?; var verification: VerificationSpec?; var confirmed = false; var index = 0
            while index < rest.count {
                switch rest[index] {
                case "--json": break
                case "--yes", "--confirmed": confirmed = true
                case "--arguments", "--expected-output", "--expect-output", "--verify-json":
                    let flag = rest[index]; index += 1
                    guard index < rest.count else { throw RightClickError("Missing option value.") }
                    if flag == "--verify-json" {
                        guard verification == nil, rest[index].utf8.count <= 32_768 else { throw RightClickError("Duplicate or oversized verification option.") }
                        verification = try JSONDecoder().decode(VerificationSpec.self, from: Data(rest[index].utf8))
                    } else if flag == "--expected-output" || flag == "--expect-output" {
                        guard expected == nil else { throw RightClickError("Duplicate option.") }
                        expected = rest[index]
                    } else {
                        guard arguments == nil, rest[index].utf8.count <= 32_768,
                              let data = rest[index].data(using: .utf8),
                              let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                            throw RightClickError("Arguments must be one JSON object containing strings only.")
                        }
                        arguments = decoded
                    }
                default:
                    guard !rest[index].hasPrefix("--") else { throw RightClickError("Unknown option.") }
                    positional.append(rest[index])
                }
                index += 1
            }
            guard command == "run" || (arguments == nil && expected == nil && verification == nil && !confirmed) else {
                throw RightClickError("Invocation options are only valid with run.")
            }
            switch command {
            case "inspect":
                guard positional.count == 1 else { throw RightClickError("inspect needs one item.") }
                print(RightClickJSON.encode(try engine.inspect(positional[0])))
            case "actions", "capabilities":
                guard positional.count == 1 else { throw RightClickError("actions needs one item.") }
                let result = try engine.capabilities(for: positional[0])
                print(RightClickJSON.encode(ActionList(item: result.item, actions: result.capabilities)))
            case "explain", "describe":
                guard positional.count == 2 else { throw RightClickError("explain needs action ID and item.") }
                print(RightClickJSON.encode(try engine.describe(id: positional[0], item: positional[1])))
            case "providers":
                guard positional.isEmpty else { throw RightClickError("providers takes no item.") }
                print(RightClickJSON.encode(engine.providers()))
            case "status":
                guard positional.count == 1 else { throw RightClickError("status needs one execution ID.") }
                print(RightClickJSON.encode(engine.executionStatus(positional[0])))
            case "run":
                guard positional.count == 2 else { throw RightClickError("run needs action ID and item.") }
                let result = try engine.run(id: positional[0], item: positional[1], confirmed: confirmed,
                    arguments: arguments, expectedOutput: expected, verification: verification)
                print(RightClickJSON.encode(result))
                switch result.status {
                case .accepted, .verified: return 0
                case .confirmationRequired: return 3
                case .unsupported, .unavailable: return 4
                case .rejected, .failed, .unknown: return 1
                }
            default: throw RightClickError("Unknown or host-specific command. Use rightclick help.")
            }
            return 0
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); return 2 }
    }
}
#endif
