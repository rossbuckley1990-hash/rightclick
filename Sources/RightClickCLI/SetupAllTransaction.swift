import Foundation

enum RightClickSetupAllTransaction {
    struct PreparedClient {
        let adapter:
            any RightClickClientAdapter

        let plan:
            RightClickOnboardingPlan
    }

    struct AppliedClient {
        let prepared:
            PreparedClient

        let result:
            RightClickOnboardingApplied
    }

    struct PreflightFailure:
        Error,
        CustomStringConvertible
    {
        let clientID: String
        let underlying: Error

        var description: String {
            String(
                describing:
                    underlying
            )
        }
    }

    struct ApplyFailure:
        Error,
        CustomStringConvertible
    {
        let clientID: String
        let rollbackStatus: String
        let underlying: Error
        let rollbackErrors: [String]

        var description: String {
            var text =
                String(
                    describing:
                        underlying
                )

            if !rollbackErrors.isEmpty {
                text +=
                    " Transaction rollback errors: "
                    + rollbackErrors
                        .joined(
                            separator: " | "
                        )
            }

            return text
        }
    }

    static func preflight(
        adapters:
            [any RightClickClientAdapter],
        home: URL,
        executable: String,
        disconnect: Bool
    ) throws
        -> [PreparedClient]
    {
        var prepared:
            [PreparedClient] = []

        for adapter in adapters {
            do {
                let plan =
                    try RightClickOnboardingEngine
                        .plan(
                            adapter:
                                adapter,
                            home:
                                home,
                            executable:
                                executable,
                            disconnect:
                                disconnect
                        )

                prepared.append(
                    PreparedClient(
                        adapter:
                            adapter,
                        plan:
                            plan
                    )
                )
            } catch {
                throw PreflightFailure(
                    clientID:
                        adapter.id,
                    underlying:
                        error
                )
            }
        }

        return prepared
    }

    static func apply(
        _ prepared:
            [PreparedClient]
    ) throws
        -> [AppliedClient]
    {
        var applied:
            [AppliedClient] = []

        for client in prepared {
            do {
                let result =
                    try RightClickOnboardingEngine
                        .apply(
                            client.plan
                        )

                applied.append(
                    AppliedClient(
                        prepared:
                            client,
                        result:
                            result
                    )
                )
            } catch {
                var rollbackErrors:
                    [String] = []

                var rollbackRequired =
                    false

                for prior in
                    applied.reversed()
                {
                    guard
                        prior
                            .prepared
                            .plan
                            .mutation
                            .changed
                    else {
                        continue
                    }

                    rollbackRequired =
                        true

                    do {
                        try RightClickOnboardingEngine
                            .rollback(
                                prior.prepared.plan,
                                applied:
                                    prior.result
                            )
                    } catch {
                        rollbackErrors.append(
                            prior
                                .prepared
                                .plan
                                .clientID
                            + ": "
                            + String(
                                describing:
                                    error
                            )
                        )
                    }
                }

                let rollbackStatus:
                    String

                if !rollbackRequired {
                    rollbackStatus =
                        "NOT_REQUIRED"
                } else if
                    rollbackErrors.isEmpty
                {
                    rollbackStatus =
                        "RESTORED"
                } else {
                    rollbackStatus =
                        "ROLLBACK_FAILED"
                }

                throw ApplyFailure(
                    clientID:
                        client.plan.clientID,
                    rollbackStatus:
                        rollbackStatus,
                    underlying:
                        error,
                    rollbackErrors:
                        rollbackErrors
                )
            }
        }

        return applied
    }
}
