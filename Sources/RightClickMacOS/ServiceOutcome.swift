import RightClickProviders
import RightClickProtocol
import Foundation

/// A public invocation flag and returned data are observations, not success.
/// An explicit caller postcondition can verify a returned-text task only.
enum ServiceOutcome {
    static func result(actionID: String, title: String, returned: Bool?,
                       pasteboardChanged: Bool, returnedText: String?, expectedOutput: String?, inputText: String? = nil) -> RunResult {
        guard let returned else {
            return RunResult(status: .unknown, actionID: actionID, title: title,
                             message: "The invocation deadline elapsed. The provider may still act.",
                             evidence: OutcomeEvidence(type: "invocation_timeout", boundary: "No completed invocation or outcome observation."))
        }
        guard returned else {
            return RunResult(status: .rejected, actionID: actionID, title: title,
                             message: "NSPerformService returned false.",
                             evidence: OutcomeEvidence(type: "provider_rejection", boundary: "The public invocation API rejected the request."))
        }
        // Never return unchanged input as if it were provider output.
        let output = pasteboardChanged ? returnedText : nil
        var evidence = OutcomeEvidence(type: output == nil ? "provider_acceptance" : "provider_returned_text",
                                       boundary: "Provider accepted the request. Its intended external outcome has not been independently verified.")
        var status = RunStatus.accepted
        var message = "NSPerformService returned true; semantic outcome is unverified."
        if let expectedOutput {
            if let output, let inputText, output != inputText {
                let matched = output == expectedOutput
                status = matched ? .verified : .failed
                evidence = OutcomeEvidence(type: "returned_text_postcondition",
                    boundary: "Compared provider-written, declared text output with the caller's exact expected text. This verifies only that returned-text outcome, not external side effects.",
                    outcomeVerified: matched)
                message = matched ? "Returned text matches the explicit postcondition." : "Returned text does not match the explicit postcondition."
            } else {
                message = "Provider accepted the request but supplied no non-echoed declared text output with known input; the postcondition is unverified."
            }
        }
        return RunResult(status: status, actionID: actionID, title: title, message: message,
                         output: output, supportLevel: .publicSupported, evidence: evidence)
    }
}
