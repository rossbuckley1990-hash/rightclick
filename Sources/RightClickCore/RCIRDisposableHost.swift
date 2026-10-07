/// Trusted composition for an explicitly disposable capability environment.
/// It uses the normal admission/verification engine with confirmation policy,
/// and acquires no installed policy, observers or production signing references.
extension RCIRExecutionHost {
    public static func disposable() -> RCIRExecutionHost {
        let host = RCIRExecutionHost()
        host.configuration = { RCIRHostConfiguration() }
        return host
    }
}
