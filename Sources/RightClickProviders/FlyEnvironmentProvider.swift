import Foundation
import RightClickProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Operator-only immutable configuration. This is never decoded from an MCP
/// request. The image must supply the audited helper contract described in
/// NESTED-PROVIDER.md; this repository does not ship such an image.
public struct FlyEnvironmentProfile {
    public let app: String
    public let region: String
    public let ownerID: String
    public let ceiling: EnvironmentSpec
    public let manifest: EnvironmentRuntimeManifest
    public let image: String
    public let maximumMicroUSDPerSecond: Int64
    public init(app: String, region: String, ownerID: String, ceiling: EnvironmentSpec,
                manifest: EnvironmentRuntimeManifest, image: String, maximumMicroUSDPerSecond: Int64) throws {
        guard Self.safeLabel(app, maximum: 63), Self.safeLabel(region, maximum: 16),
              EnvironmentIdentity.isCanonicalID(ownerID), manifest.architecture == "x86_64",
              Self.validImage(image), (1...EnvironmentLimits.maximumCostUnits).contains(maximumMicroUSDPerSecond) else {
            throw EnvironmentError.invalidManifest
        }
        self.app = app; self.region = region; self.ownerID = ownerID; self.ceiling = ceiling
        self.manifest = manifest; self.image = image; self.maximumMicroUSDPerSecond = maximumMicroUSDPerSecond
    }
    fileprivate static func safeLabel(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.utf8.count) && value.first != "-" && value.last != "-" &&
            value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    private static func validImage(_ image: String) -> Bool {
        let components = image.components(separatedBy: "@sha256:")
        guard components.count == 2, EnvironmentIdentity.isDigest(components[1]), components[0].utf8.count <= 256 else { return false }
        let path = components[0].split(separator: "/", omittingEmptySubsequences: false)
        return path.count >= 2 && path.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
            }
        }
    }
}

/// An installed host safety authority, not a caller assertion or configuration
/// Boolean. Implementations must protect dispatch reservations across restarts
/// and independently enforce the exact expiry even if the parent/guest crashes.
/// No implementation is provided here because Fly has no documented hard VM TTL.
public protocol FlyEnvironmentCreationGuard: AnyObject {
    var enforcesProviderVisibleLifetime: Bool { get }
    /// True exactly once for a durable intent; false after any uncertain dispatch.
    /// Must check the approved image, lifetime and conservative total spend bound.
    func reserveCreation(_ intent: EnvironmentCreateIntent, profile: FlyEnvironmentProfile) throws -> Bool
}

public struct FlyMachinesResponse {
    public let statusCode: Int
    public let url: URL
    public let body: Data
    public init(statusCode: Int, url: URL, body: Data) {
        self.statusCode = statusCode; self.url = url; self.body = body
    }
}
/// Host-injected transport for contract tests. Production uses bounded TLS HTTP.
public protocol FlyMachinesTransport: AnyObject {
    func send(_ request: URLRequest) throws -> FlyMachinesResponse
}

public final class FlyEnvironmentProvider: EnvironmentProvider, EnvironmentProviderRecovery {
    public let id = "fly-machines"
    public var support: EnvironmentProviderSupport {
        let guarded = creationGuard?.enforcesProviderVisibleLifetime == true
        return EnvironmentProviderSupport(supportsCreate: guarded, supportsBootstrap: guarded,
            supportsChallenge: guarded, supportsStop: true, supportsDestroy: true,
            enforcesTTL: guarded, nativeCreateIdempotency: false)
    }
    private let profile: FlyEnvironmentProfile
    private let credential: () throws -> String
    private let transport: FlyMachinesTransport
    private let creationGuard: FlyEnvironmentCreationGuard?
    private let clock: () -> Int64
    private let lock = NSRecursiveLock()
    private var intents: [String: EnvironmentCreateIntent] = [:]
    private var resourceIDs: [String: String] = [:]
    private var dispatched: Set<String> = []
    private var operationKeys: [String: String] = [:]
    private var challenges: [String: String] = [:]

    public init(profile: FlyEnvironmentProfile, credential: @escaping () throws -> String,
                creationGuard: FlyEnvironmentCreationGuard? = nil, transport: FlyMachinesTransport? = nil,
                clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.profile = profile; self.credential = credential; self.creationGuard = creationGuard
        self.transport = transport ?? FlyBoundedHTTPTransport(); self.clock = clock
    }

    /// Host-only restart recovery from the protected environment ledger. The
    /// host must authenticate ledger provenance before calling this; accepting
    /// an MCP-supplied observation here would violate the trust boundary.
    public func restoreObservedBinding(intent: EnvironmentCreateIntent, observation: EnvironmentObservation) throws {
        lock.lock(); defer { lock.unlock() }
        guard observation.presence == .present, observation.environmentID == intent.environmentID,
              observation.correlationID == intent.correlationID, observation.observationBoundary == "authenticated-fly-machines-api",
              let resourceID = observation.providerResourceID, Self.safeMachineID(resourceID),
              intent.spec.isWithin(profile.ceiling), intents[intent.correlationID].map({ $0 == intent }) ?? true,
              resourceIDs[intent.correlationID].map({ $0 == resourceID }) ?? true else { throw EnvironmentError.invalidObservation }
        intents[intent.correlationID] = intent; resourceIDs[intent.correlationID] = resourceID
        dispatched.insert(intent.correlationID)
    }

    public func create(_ intent: EnvironmentCreateIntent) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }
        try validateSpec(intent)
        guard support.supportsCreate, let creationGuard else { throw EnvironmentError.unsupported }
        if let previous = intents[intent.correlationID], previous != intent { throw EnvironmentError.idempotencyConflict }
        // Save the exact local intent before any effect. Durable Core and guard
        // reservations remain authoritative after this provider object restarts.
        intents[intent.correlationID] = intent
        let matches = try matchingMachines(correlationID: intent.correlationID)
        guard matches.count <= 1 else { throw EnvironmentError.unsafeDuplicate }
        if let match = matches.first {
            try bind(match, to: intent)
            return try accepted(match.id)
        }
        guard !dispatched.contains(intent.correlationID), try creationGuard.reserveCreation(intent, profile: profile) else {
            return try EnvironmentProviderAcceptance(acceptance: .unknown, message: "Creation was already reserved; reconcile without resubmitting.")
        }
        dispatched.insert(intent.correlationID)
        let response: FlyMachinesResponse
        do { response = try send(method: "POST", body: createBody(intent)) }
        catch { return try EnvironmentProviderAcceptance(acceptance: .unknown, message: "Creation dispatch is uncertain; reconcile the original correlation.") }
        guard (200...299).contains(response.statusCode) else {
            return try EnvironmentProviderAcceptance(acceptance: .unknown, message: "Creation was not confirmed; original correlation remains reserved.")
        }
        let machine = try decodeMachine(response.body)
        try bind(machine, to: intent)
        return try accepted(machine.id) // This is still not presence/readiness.
    }

    public func observe(correlationID: String) throws -> EnvironmentObservation {
        lock.lock(); defer { lock.unlock() }
        guard EnvironmentIdentity.isCanonicalID(correlationID) else { throw EnvironmentError.invalidIdentity }
        if let resourceID = resourceIDs[correlationID], let intent = intents[correlationID] {
            do {
                let response = try send(method: "GET", machineID: resourceID)
                if response.statusCode == 404 {
                    // Only a previously authenticated full marker binding allows
                    // this exact locator's authenticated 404 to establish absence.
                    return try observed(intent, resourceID: resourceID, presence: .absent, state: .destroyed)
                }
                guard response.statusCode == 200 else { return try unknown(intent, resourceID: resourceID) }
                let machine = try decodeMachine(response.body); try bind(machine, to: intent)
                return try observation(machine, intent: intent)
            } catch { return try unknown(intent, resourceID: resourceID) }
        }
        let matches = try matchingMachines(correlationID: correlationID)
        guard matches.count == 1 else {
            if matches.count > 1 { throw EnvironmentError.unsafeDuplicate }
            // An empty listing cannot prove that an unbound uncertain create
            // never happened (eventual consistency, parent crash, provider lag).
            if let intent = intents[correlationID] { return try unknown(intent, resourceID: nil) }
            throw EnvironmentError.unavailable
        }
        let machine = matches[0]
        let intent = try intentFromMarkers(machine)
        try bind(machine, to: intent); intents[correlationID] = intent
        return try observe(correlationID: correlationID) // Exact GET, including authenticated 404.
    }
    public func list() throws -> [EnvironmentObservation] {
        lock.lock(); defer { lock.unlock() }
        let machines = try allMachines()
        var correlations = Set<String>()
        var observations: [EnvironmentObservation] = []
        for machine in machines where machine.metadata["rightclick_owner"] == profile.ownerID {
            let intent = try intentFromMarkers(machine)
            guard correlations.insert(intent.correlationID).inserted else { throw EnvironmentError.unsafeDuplicate }
            try bind(machine, to: intent); intents[intent.correlationID] = intent
            observations.append(try observe(correlationID: intent.correlationID))
        }
        return observations.sorted { $0.correlationID < $1.correlationID }
    }

    public func bootstrap(_ handle: EnvironmentHandle, manifest: EnvironmentRuntimeManifest) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }
        guard support.supportsBootstrap, manifest == profile.manifest, handle.expiresAtMilliseconds > clock() else { throw EnvironmentError.unsupported }
        try authenticate(handle)
        let current = try send(method: "GET", machineID: handle.providerResourceID)
        guard current.statusCode == 200 else { return try uncertain() }
        if try decodeMachine(current.body).state != "started" {
            let start = try send(method: "POST", machineID: handle.providerResourceID, action: "start", body: [:])
            guard (200...299).contains(start.statusCode) else { return try uncertain() }
        }
        // The audited image owns ephemeral key generation. No parent private
        // key, cloud token or general command enters the bootstrap payload.
        return try execute(handle, verb: "bootstrap", payload: ["environmentID": handle.environmentID,
            "manifest": try encodedObject(manifest)])
    }
    public func executeChallenge(_ handle: EnvironmentHandle, executionID: String, challenge: String) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }
        guard support.supportsChallenge, EnvironmentIdentity.isCanonicalID(executionID), validChallenge(challenge),
              handle.expiresAtMilliseconds > clock() else { throw EnvironmentError.invalidIdentity }
        try authenticate(handle)
        let key = handle.environmentID + ":" + executionID
        if let prior = challenges[key], prior != challenge { throw EnvironmentError.idempotencyConflict }
        challenges[key] = challenge
        return try execute(handle, verb: "challenge", payload: ["environmentID": handle.environmentID,
            "executionID": executionID, "challenge": challenge])
    }
    public func observeChallenge(_ handle: EnvironmentHandle, executionID: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard support.supportsChallenge, EnvironmentIdentity.isCanonicalID(executionID) else { throw EnvironmentError.unsupported }
        try authenticate(handle)
        let result = try helper(handle.providerResourceID, verb: "observe-challenge", payload: [
            "environmentID": handle.environmentID, "executionID": executionID])
        guard Set(result.keys).isSubset(of: ["environmentID", "executionID", "challenge"]),
              result["environmentID"] as? String == handle.environmentID, result["executionID"] as? String == executionID else {
            throw EnvironmentError.invalidObservation
        }
        if result["challenge"] is NSNull { return nil }
        guard let value = result["challenge"] as? String, validChallenge(value) else { throw EnvironmentError.invalidObservation }
        return value // A separate exact predicate must compare the random challenge.
    }
    public func stop(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }
        try reserveOperation("stop", handle: handle, key: idempotencyKey); try authenticate(handle)
        let response = try send(method: "POST", machineID: handle.providerResourceID, action: "stop",
            body: ["signal": "SIGTERM", "timeout": 5_000_000_000])
        return try (200...299).contains(response.statusCode) ? accepted(handle.providerResourceID) : uncertain()
    }
    public func destroy(_ handle: EnvironmentHandle, idempotencyKey: String) throws -> EnvironmentProviderAcceptance {
        lock.lock(); defer { lock.unlock() }
        try reserveOperation("destroy", handle: handle, key: idempotencyKey); try authenticate(handle, allowAbsent: true)
        let response = try send(method: "DELETE", machineID: handle.providerResourceID)
        return try (200...299).contains(response.statusCode) || response.statusCode == 404 ? accepted(handle.providerResourceID) : uncertain()
    }

    private func validateSpec(_ intent: EnvironmentCreateIntent) throws {
        guard intent.spec.isWithin(profile.ceiling), intent.createdAtMilliseconds <= clock(), intent.expiresAtMilliseconds > clock() else {
            throw EnvironmentError.invalidLimits
        }
        let seconds = (intent.spec.lifetimeMilliseconds + 999) / 1_000
        let (cost, overflow) = seconds.multipliedReportingOverflow(by: profile.maximumMicroUSDPerSecond)
        guard !overflow, cost <= intent.spec.resources.maximumCostUnits else { throw EnvironmentError.invalidLimits }
    }
    private func createBody(_ intent: EnvironmentCreateIntent) throws -> [String: Any] {
        let argv = ["/usr/local/bin/rightclick-environment-runtime", "serve"]
        return ["name": "rc-" + intent.correlationID.lowercased(), "region": profile.region,
            "skip_launch": true, "config": ["image": profile.image, "auto_destroy": true,
                "restart": ["policy": "no"], "guest": ["cpu_kind": "shared", "cpus": intent.spec.resources.cpuCount,
                    "memory_mb": intent.spec.resources.memoryMiB], "services": [], "mounts": [],
                "rootfs": ["persist": "never", "size_gb": 1],
                "processes": [["exec": argv, "ignore_app_secrets": true, "secrets": [],
                    "env": ["RIGHTCLICK_ENVIRONMENT_ID": intent.environmentID,
                            "RIGHTCLICK_EXPIRES_AT_MS": String(intent.expiresAtMilliseconds)]]],
                "metadata": try metadata(intent)]]
    }
    private func metadata(_ intent: EnvironmentCreateIntent) throws -> [String: String] {
        ["rightclick_owner": profile.ownerID, "rightclick_environment": intent.environmentID,
         "rightclick_correlation": intent.correlationID, "rightclick_intent_sha256": try intent.digest(),
         "rightclick_intent": try JSONEncoder().encode(intent).base64EncodedString(),
         "rightclick_image": profile.image]
    }
    private struct Machine {
        let id: String
        let state: String
        let metadata: [String: String]
        let image: String
    }
    private func decodeMachine(_ data: Data) throws -> Machine {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EnvironmentError.invalidObservation }
        return try machine(object)
    }
    private func machine(_ object: [String: Any]) throws -> Machine {
        guard let id = object["id"] as? String, Self.safeMachineID(id), let state = object["state"] as? String,
              let config = object["config"] as? [String: Any], let metadata = config["metadata"] as? [String: String],
              metadata.count <= 32, metadata.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 16_384 }),
              let image = config["image"] as? String else { throw EnvironmentError.invalidObservation }
        return Machine(id: id, state: state, metadata: metadata, image: image)
    }
    private func allMachines() throws -> [Machine] {
        let response = try send(method: "GET")
        guard response.statusCode == 200, let objects = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]],
              objects.count <= 1024 else { throw EnvironmentError.unavailable }
        // Ignore unowned resources without parsing their unrelated config.
        return try objects.filter { object in
            ((object["config"] as? [String: Any])?["metadata"] as? [String: String])?["rightclick_owner"] == profile.ownerID
        }.map(machine)
    }
    private func matchingMachines(correlationID: String) throws -> [Machine] {
        try allMachines().filter { $0.metadata["rightclick_correlation"] == correlationID }
    }
    private func intentFromMarkers(_ machine: Machine) throws -> EnvironmentCreateIntent {
        guard machine.metadata["rightclick_owner"] == profile.ownerID,
              let encoded = machine.metadata["rightclick_intent"], let data = Data(base64Encoded: encoded), data.count <= 8_192 else {
            throw EnvironmentError.invalidObservation
        }
        let intent = try JSONDecoder().decode(EnvironmentCreateIntent.self, from: data)
        try bind(machine, to: intent)
        return intent
    }
    private func bind(_ machine: Machine, to intent: EnvironmentCreateIntent) throws {
        guard machine.metadata["rightclick_owner"] == profile.ownerID, machine.image == profile.image,
              machine.metadata["rightclick_image"] == profile.image,
              machine.metadata["rightclick_environment"] == intent.environmentID,
              machine.metadata["rightclick_correlation"] == intent.correlationID,
              machine.metadata["rightclick_intent_sha256"] == (try intent.digest()),
              intent.spec.isWithin(profile.ceiling),
              intents[intent.correlationID].map({ $0 == intent }) ?? true,
              resourceIDs[intent.correlationID].map({ $0 == machine.id }) ?? true else { throw EnvironmentError.invalidObservation }
        resourceIDs[intent.correlationID] = machine.id
    }
    private func authenticate(_ handle: EnvironmentHandle, allowAbsent: Bool = false) throws {
        guard handle.providerID == id, Self.safeMachineID(handle.providerResourceID) else { throw EnvironmentError.invalidIdentity }
        if intents[handle.correlationID] == nil { _ = try observe(correlationID: handle.correlationID) }
        guard let intent = intents[handle.correlationID], resourceIDs[handle.correlationID] == handle.providerResourceID,
              intent.environmentID == handle.environmentID, intent.lineage == handle.lineage, intent.spec == handle.spec,
              intent.createdAtMilliseconds == handle.createdAtMilliseconds, intent.expiresAtMilliseconds == handle.expiresAtMilliseconds else {
            throw EnvironmentError.invalidIdentity
        }
        let response = try send(method: "GET", machineID: handle.providerResourceID)
        if response.statusCode == 404 && allowAbsent { return }
        guard response.statusCode == 200 else { throw EnvironmentError.unavailable }
        try bind(decodeMachine(response.body), to: intent)
    }
    private func observation(_ machine: Machine, intent: EnvironmentCreateIntent) throws -> EnvironmentObservation {
        let state: EnvironmentState
        switch machine.state {
        case "created", "starting": state = .bootstrapping
        case "started": state = .bootstrapping // Ready requires independent runtime facts.
        case "stopping", "stopped", "suspended": state = .stopping
        case "destroying", "destroyed": state = .destroying // Exact 404 establishes absence.
        default: return try unknown(intent, resourceID: machine.id)
        }
        var runtime: EnvironmentRuntimeObservation?
        if machine.state == "started", support.supportsBootstrap {
            // Failure to observe a child never changes presence into absence.
            if let object = try? helper(machine.id, verb: "observe-runtime", payload: ["environmentID": intent.environmentID]),
               Set(object.keys) == Set(["environmentID", "runtime"]), object["environmentID"] as? String == intent.environmentID,
               let value = object["runtime"], let data = try? JSONSerialization.data(withJSONObject: value),
               let observedRuntime = try? JSONDecoder().decode(EnvironmentRuntimeObservation.self, from: data),
               observedRuntime.manifest == profile.manifest, observedRuntime.observedAtMilliseconds <= clock(),
               observedRuntime.observedAtMilliseconds >= clock() - 5_000 {
                runtime = try EnvironmentRuntimeObservation(manifest: observedRuntime.manifest, publicKey: observedRuntime.publicKey,
                    observedAtMilliseconds: observedRuntime.observedAtMilliseconds, observationBoundary: "authenticated-fly-machine-exec-runtime-observer")
            }
        }
        return try observed(intent, resourceID: machine.id, presence: .present, state: runtime == nil ? state : .ready, runtime: runtime)
    }
    private func observed(_ intent: EnvironmentCreateIntent, resourceID: String?, presence: EnvironmentPresence,
                          state: EnvironmentState, runtime: EnvironmentRuntimeObservation? = nil) throws -> EnvironmentObservation {
        try EnvironmentObservation(environmentID: intent.environmentID, correlationID: intent.correlationID,
            providerResourceID: resourceID, presence: presence, state: state, observedAtMilliseconds: max(1, clock()),
            runtime: runtime, observationBoundary: "authenticated-fly-machines-api")
    }
    private func unknown(_ intent: EnvironmentCreateIntent, resourceID: String?) throws -> EnvironmentObservation {
        try observed(intent, resourceID: resourceID, presence: .unknown, state: .unknown)
    }
    private func reserveOperation(_ kind: String, handle: EnvironmentHandle, key: String) throws {
        guard EnvironmentIdentity.isCanonicalID(key) else { throw EnvironmentError.invalidIdentity }
        let value = kind + ":" + handle.environmentID + ":" + handle.providerResourceID
        if let prior = operationKeys[key], prior != value { throw EnvironmentError.idempotencyConflict }
        operationKeys[key] = value
    }
    private func execute(_ handle: EnvironmentHandle, verb: String, payload: [String: Any]) throws -> EnvironmentProviderAcceptance {
        _ = try helper(handle.providerResourceID, verb: verb, payload: payload)
        return try accepted(handle.providerResourceID)
    }
    private func helper(_ machineID: String, verb: String, payload: [String: Any]) throws -> [String: Any] {
        guard ["bootstrap", "challenge", "observe-challenge", "observe-runtime"].contains(verb) else { throw EnvironmentError.unsupported }
        let input = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard input.count <= 8_192, let stdin = String(data: input, encoding: .utf8) else { throw EnvironmentError.invalidLimits }
        let response = try send(method: "POST", machineID: machineID, action: "exec", body: [
            "command": ["/usr/local/bin/rightclick-environment-runtime", verb], "stdin": stdin, "timeout": 3])
        guard response.statusCode == 200, let result = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              result["exit_code"] as? Int == 0, let stdout = result["stdout"] as? String, stdout.utf8.count <= 8_192,
              let data = stdout.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnvironmentError.unavailable
        }
        // Exit zero is only a usable transport response, never semantic proof.
        return object
    }
    private func encodedObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private func accepted(_ resourceID: String) throws -> EnvironmentProviderAcceptance {
        try EnvironmentProviderAcceptance(acceptance: .accepted, providerResourceID: resourceID,
            message: "Provider accepted; exact independent observation required.")
    }
    private func uncertain() throws -> EnvironmentProviderAcceptance {
        try EnvironmentProviderAcceptance(acceptance: .unknown, message: "Provider effect is uncertain; reconcile before retry.")
    }
    private func validChallenge(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= EnvironmentLimits.maximumChallengeBytes &&
            value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    private static func safeMachineID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func send(method: String, machineID: String? = nil, action: String? = nil, body: [String: Any]? = nil) throws -> FlyMachinesResponse {
        if let machineID, !Self.safeMachineID(machineID) { throw EnvironmentError.invalidIdentity }
        if let action, !["start", "stop", "exec"].contains(action) { throw EnvironmentError.unsupported }
        var path = "https://api.machines.dev/v1/apps/" + profile.app + "/machines"
        if let machineID { path += "/" + machineID }
        if let action { path += "/" + action }
        if method == "GET" && machineID == nil { path += "?include_deleted=true" }
        guard let url = URL(string: path) else { throw EnvironmentError.invalidIdentity }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        let token: String
        do { token = try credential() } catch { throw EnvironmentError.unavailable }
        guard !token.isEmpty, token.utf8.count <= 8_192, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw EnvironmentError.unavailable
        }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response: FlyMachinesResponse
        do { response = try transport.send(request) } catch { throw EnvironmentError.unavailable }
        guard response.url == url, !(300...399).contains(response.statusCode), response.body.count <= 1_048_576 else {
            throw EnvironmentError.unavailable
        }
        return response
    }
}

/// No redirects, cookies, cached responses, inherited URL credentials or
/// unbounded response buffering. Errors are mapped before crossing the boundary.
private final class FlyBoundedHTTPTransport: FlyMachinesTransport {
    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var body = Data()
        var response: HTTPURLResponse?
        var failed = false
        var finished = false
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard response.expectedContentLength <= 1_048_576, let http = response as? HTTPURLResponse else {
                failed = true; completionHandler(.cancel); return
            }
            self.response = http; completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count > 1_048_576 - body.count { failed = true; dataTask.cancel() }
            else if !failed { body.append(data) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); failed = failed || error != nil; finished = true; lock.unlock(); semaphore.signal()
        }
    }
    func send(_ request: URLRequest) throws -> FlyMachinesResponse {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        let loader = Loader()
        let session = URLSession(configuration: config, delegate: loader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request); task.resume()
        guard loader.semaphore.wait(timeout: .now() + .seconds(5)) == .success else {
            task.cancel(); throw EnvironmentError.unavailable
        }
        loader.lock.lock(); defer { loader.lock.unlock() }
        guard !loader.failed, loader.finished, let response = loader.response, let url = response.url else { throw EnvironmentError.unavailable }
        return FlyMachinesResponse(statusCode: response.statusCode, url: url, body: loader.body)
    }
}
