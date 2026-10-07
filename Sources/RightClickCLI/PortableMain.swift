#if !os(macOS)
import Foundation
#if os(Windows)
import ucrt
#endif
import RightClickCore
import RightClickMCP

@main
struct RightClickPortableMain {
    static func main() { exit(Int32(run(Array(CommandLine.arguments.dropFirst())))) }
    static func run(_ args: [String]) -> Int {
        let command = args.first ?? "help"
        let rest = Array(args.dropFirst())
        if ["connect", "config", "platform"].contains(command) {
            return PortableCommands.run(command, arguments: rest)
        }
        if command == "mcp" { return RightClickMCPMain.run(rest) }
        if command == "provider" { return RightClickProviderCLI.run(rest) }
        if command == "version" || command == "--version" { print(RightClickVersion.current); return 0 }
        if ["help", "--help", "-h"].contains(command) {
            print("""
            RIGHTCLICK portable capability runtime
              rightclick mcp                         MCP over stdio
              rightclick mcp --http --port 8765      Local HTTP; requires RIGHTCLICK_MCP_TOKEN
              rightclick connect                    Print client JSON; no configuration changes
              rightclick connect --openapi URL --base-url URL
              rightclick connect --graphql URL
              rightclick connect --grpc grpcs://host:port
              rightclick platform --json            Report compiled host features
              rightclick doctor --json              Inspect runtime without invoking providers
              rightclick inspect ITEM --json
              rightclick actions ITEM --json
              rightclick explain ACTION_ID ITEM --json
              rightclick run ACTION_ID ITEM [--arguments JSON] [--expected-output TEXT] [--yes]
              rightclick providers --json
              rightclick provider ...               Existing provider registry commands

            Native desktop services and Keychain require macOS. Headless hosts use
            configured capability artifacts, ARD registries and explicit environment
            authority bindings. Discovery is not approval; acceptance is not verification.
            """)
            return 0
        }
        do {
            if command == "doctor" {
                guard rest.allSatisfy({ $0 == "--json" }) else { throw RightClickError("doctor only accepts --json.") }
                print(RightClickJSON.encode(RuntimePlatform.report())); return 0
            }
            var positional: [String] = []; var arguments: CapabilityArguments?
            var expected: String?; var confirmed = false; var index = 0
            while index < rest.count {
                switch rest[index] {
                case "--json": break
                case "--yes": confirmed = true
                case "--arguments", "--expected-output":
                    let flag = rest[index]; index += 1
                    guard index < rest.count else { throw RightClickError("Missing option value.") }
                    if flag == "--expected-output" {
                        guard expected == nil else { throw RightClickError("Duplicate option.") }
                        expected = rest[index]
                    } else {
                        guard arguments == nil, rest[index].utf8.count <= 1_048_576,
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
            guard command == "run" || (arguments == nil && expected == nil && !confirmed) else {
                throw RightClickError("Invocation options are only valid with run.")
            }
            let engine = RightClickMCPRuntime.makeEngine(startBrowsing: false)
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
            case "run":
                guard positional.count == 2 else { throw RightClickError("run needs action ID and item.") }
                let result = try engine.run(id: positional[0], item: positional[1], confirmed: confirmed,
                    arguments: arguments, expectedOutput: expected)
                print(RightClickJSON.encode(result))
                return [.accepted, .verified].contains(result.status) ? 0 : 1
            default:
                throw RightClickError("Unknown or host-specific command. Use rightclick help.")
            }
            return 0
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); return 2 }
    }
}
#endif

