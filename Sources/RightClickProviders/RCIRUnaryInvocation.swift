import RightClickProtocol
import Foundation

/// Common host admission for existing unary compilers whose public ABI accepts
/// string arguments and returns serialized text. Compilers supply their closed
/// names and constraints; this boundary never guesses types from descriptions.
enum RCIRUnaryInvocation {
    static func execute(capability: Capability, owner: Capability, item: ContentItem,
                        executionID: String, arguments: CapabilityArguments?,
                        names: [String], required: [String], target: URL,
                        verification: VerificationSpec?, expectedOutput: String?,
                        host: RCIRExecutionHost, available: @escaping () -> Bool,
                        revalidate: @escaping () -> Bool,
                        invoke: (_ admit: (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord) throws -> ExecutionRecord {
        // Compiler mistakes and caller input failures must fail before transport,
        // including duplicate names that would otherwise trap dictionary creation.
        guard names.count <= 1_024, Set(names).count == names.count,
              Set(required).count == required.count, Set(required).isSubset(of: Set(names)),
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }) else {
            return failure(capability, executionID, "The compiler supplied an invalid closed argument contract.")
        }
        let schema = CapabilitySchema.object(properties: Dictionary(uniqueKeysWithValues: names.map { ($0, .string) }), required: required)
        let input = CapabilityValue.fromLegacyArguments(arguments) ?? .object([:])
        do { try schema.validate(input) }
        catch { return failure(capability, executionID, "Arguments violated the reflected unary contract: \(error)") }
        let declaration = CapabilityDispatchContract.withoutExperience(owner)
        let discovery = try declaration.abiContract(arguments: schema, result: .string)
        let contract = CapabilityContract(capabilityID: discovery.capabilityID, reflectorID: discovery.reflectorID,
            providerID: discovery.providerID, arguments: schema, result: .string,
            declaration: .object(["capability": discovery.declaration,
                "verification": try verification.map { .bytes(try JSONEncoder().encode($0)) } ?? .null,
                "expectedOutput": expectedOutput.map { .string($0) } ?? .null,
                "wireRepresentation": .string("compiler-validated legacy string arguments; serialized returned text")]))
        let scope = RCIRScope(target.absoluteString + "#" + capability.id, .execute)
        return try host.execute(abi: contract, discovery: discovery, arguments: input, scope: scope,
            capability: owner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput, target: target,
            authority: { available() ? [scope] : [] }, revalidate: { available() && revalidate() },
            dispatch: { _, admit in try withoutActuallyEscaping(admit) { gate in try invoke(gate) } },
            resultValue: { .string($0.output ?? "") })
    }

    private static func failure(_ capability: Capability, _ executionID: String, _ message: String) -> ExecutionRecord {
        ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
            state: .failed, message: message,
            evidence: OutcomeEvidence(type: "input_contract_failure",
                boundary: "The closed compiler argument contract was rejected before provider transport or authority consumption."))
    }
}
