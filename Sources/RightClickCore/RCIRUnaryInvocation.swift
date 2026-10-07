import Foundation

/// One common unary admission path. Each compiler supplies its exact typed
/// contract and conversion; the compatibility wrapper keeps text-only compilers
/// explicit without guessing types from descriptions.
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
        return try execute(capability: capability, owner: owner, item: item, executionID: executionID,
            arguments: arguments, argumentSchema: schema, input: input, resultSchema: .string,
            wireRepresentation: "compiler-validated legacy string arguments; serialized returned text",
            target: target, verification: verification, expectedOutput: expectedOutput,
            host: host, available: available, revalidate: revalidate, invoke: invoke,
            resultValue: { .string($0.output ?? "") })
    }

    static func execute(capability: Capability, owner: Capability, item: ContentItem,
                        executionID: String, arguments: CapabilityArguments?,
                        argumentSchema schema: CapabilitySchema, input: CapabilityValue,
                        resultSchema: CapabilitySchema, wireRepresentation: String, target: URL,
                        verification: VerificationSpec?, expectedOutput: String?,
                        host: RCIRExecutionHost, available: @escaping () -> Bool,
                        revalidate: @escaping () -> Bool,
                        invoke: (_ admit: (_ start: () -> Void) throws -> Void) throws -> ExecutionRecord,
                        resultValue: (ExecutionRecord) throws -> CapabilityValue) throws -> ExecutionRecord {
        do { try schema.validate(input) }
        catch { return failure(capability, executionID, "Arguments violated the reflected unary contract: \(error)") }
        let declaration = CapabilityExperience.withoutExperience(owner)
        let discovery = try declaration.abiContract(arguments: schema, result: resultSchema)
        let contract = CapabilityContract(capabilityID: discovery.capabilityID, reflectorID: discovery.reflectorID,
            providerID: discovery.providerID, arguments: schema, result: resultSchema,
            declaration: .object(["capability": discovery.declaration,
                "verification": try verification.map { .bytes(try JSONEncoder().encode($0)) } ?? .null,
                "expectedOutput": expectedOutput.map { .string($0) } ?? .null,
                "wireRepresentation": .string(wireRepresentation)]))
        let scope = RCIRScope(target.absoluteString + "#" + capability.id, .execute)
        return try host.execute(abi: contract, discovery: discovery, arguments: input, scope: scope,
            capability: owner, executionID: executionID, argumentStrings: arguments, item: item,
            verification: verification, expectedOutput: expectedOutput, target: target,
            authority: { available() ? [scope] : [] }, revalidate: { available() && revalidate() },
            dispatch: { _, admit in try withoutActuallyEscaping(admit) { gate in try invoke(gate) } },
            resultValue: resultValue)
    }

    private static func failure(_ capability: Capability, _ executionID: String, _ message: String) -> ExecutionRecord {
        ExecutionRecord(executionId: executionID, actionId: capability.id, title: capability.title,
            state: .failed, message: message,
            evidence: OutcomeEvidence(type: "input_contract_failure",
                boundary: "The closed compiler argument contract was rejected before provider transport or authority consumption."))
    }
}
