/// Optional host-only restart recovery. The coordinator must authenticate the
/// protected ledger and validate exact intent/observation pins before invoking
/// this method. Caller-provided observations must never enter this boundary.
/// This protocol is not a contextual capability or an MCP operation.
public protocol EnvironmentProviderRecovery: AnyObject {
    func restoreObservedBinding(intent: EnvironmentCreateIntent, observation: EnvironmentObservation) throws
}
