import Foundation

enum RightClickClientRegistry {
    static var adapters:
        [any RightClickClientAdapter]
    {
        [
            RightClickCursorClientAdapter(),
            RightClickClaudeClientAdapter(),
            RightClickCodexClientAdapter(),
        ]
    }

    static var supportedIDs:
        [String]
    {
        adapters.map { $0.id } + ["generic"]
    }

    static func adapter(
        id: String
    ) -> (any RightClickClientAdapter)? {
        adapters.first {
            $0.id == id
        }
    }

    static func detected(
        home: URL,
        applications: URL
    ) -> [any RightClickClientAdapter] {
        adapters.filter {
            $0.detected(
                home: home,
                applications: applications
            )
        }
    }
}
