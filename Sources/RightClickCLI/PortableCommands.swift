import Foundation
import RightClickCore

/// Non-mutating entry points shared by desktop and headless builds.
enum PortableCommands {
    static func run(_ command: String, arguments: [String]) -> Int {
        do {
            switch command {
            case "connect", "config":
                print(try RuntimeClientConfiguration.render(arguments: arguments))
            case "platform":
                guard arguments.allSatisfy({ $0 == "--json" }) else { throw RightClickError("platform only accepts --json.") }
                print(RightClickJSON.encode(RuntimePlatform.report()))
            default:
                throw RightClickError("Unsupported portable command.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); return 2
        }
    }
}

