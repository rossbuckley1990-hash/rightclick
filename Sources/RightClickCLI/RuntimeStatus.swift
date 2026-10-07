import Foundation
import RightClickCore
import RightClickMCP

enum RightClickStatusCLI {
    struct Client: Codable {
        let id: String
        let detected: Bool
        let registration: String
        let connection: String
    }
    struct Health: Codable {
        let runtime: String
        let providerExecution: String
        let clientConnections: String
    }
    struct Report: Codable {
        let runtime: RightClickRuntimeIdentity
        let clients: [Client]
        let providers: [ProviderSummary]
        let acquiredProviderSources: [String]
        let supportedArtifactKinds: [String]
        let providerCount: Int
        let capabilityCount: Int
        let health: Health
    }

    static func report(engine: CapabilityEngine,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       executable: String = RightClickRuntime.executablePath()) -> Report {
        let providers = engine.providers()
        let clients = RightClickClientRegistry.adapters.map { adapter -> Client in
            let detected = adapter.detected(home: home, applications: URL(fileURLWithPath: "/Applications"))
            var registration = "NOT_INSPECTED"
            if detected {
                do {
                    let plan = try RightClickOnboardingEngine.plan(adapter: adapter, home: home,
                        executable: executable, disconnect: false)
                    registration = plan.mutation.changed ? "SETUP_REQUIRED" : "CURRENT"
                } catch {
                    // Do not expose native client stderr or credential-bearing
                    // configuration while reporting an unreadable/conflicting state.
                    registration = "CONFLICT_OR_UNREADABLE"
                }
            }
            return Client(id: adapter.id, detected: detected,
                          registration: registration, connection: "NOT_OBSERVED")
        }
        return Report(runtime: RightClickRuntime.identity(transport: "cli"), clients: clients,
            providers: providers, acquiredProviderSources: Array(Set(providers.map(\.source))).sorted(),
            supportedArtifactKinds: CapabilityArtifactResolverRegistry().supportedKinds,
            providerCount: providers.count,
            capabilityCount: providers.reduce(0) { $0 + $1.capabilityTitles.count },
            health: Health(runtime: "RUNNING", providerExecution: "NOT_PROBED", clientConnections: "NOT_OBSERVED"))
    }

    static func run(_ args: [String], output: (String) -> Void = { print($0) }) -> Int {
        guard args.allSatisfy({ $0 == "--json" }), Set(args).count == args.count else {
            output("usage: rightclick status [--json] or rightclick status <execution-id> [--json]")
            return 2
        }
        let report = report(engine: RightClickMCPRuntime.makeEngine())
        if args.contains("--json") {
            output(RightClickJSON.encode(report))
        } else {
            output("RIGHTCLICK \(report.runtime.version) · \(report.runtime.channel) · \(report.runtime.platform)")
            output("Binary: \(report.runtime.executableRealPath)")
            output("SHA256: \(report.runtime.executableSHA256)")
            output("Source: \(report.runtime.gitCommit ?? "unverified")")
            output("\(report.capabilityCount) capabilities from \(report.providerCount) acquired providers")
            for client in report.clients where client.detected {
                output("\(client.id): \(client.registration); connection \(client.connection)")
            }
            output("Use rightclick doctor --fix to repair owned registrations.")
        }
        return 0
    }
}
