import Foundation

/// HTTP transport policy for capability providers whose authority is bound
/// to one explicitly selected origin.
///
/// Redirects are never followed. A redirect is another authority decision
/// and must not be granted implicitly by RIGHTCLICK.
///
/// Provider-document acquisition is additionally bounded:
///
/// - maximum body: 1 MiB inclusive
/// - wall-clock acquisition deadline: 5 seconds
enum OriginPinnedHTTP {
    static let maximumAcquisitionBytes =
        1_048_576

    static let maximumOpenAPISpecificationBytes =
        16_777_216

    static let acquisitionDeadline:
        TimeInterval = 5

    private enum AcquisitionFailure:
        LocalizedError
    {
        case responseTooLarge
        case deadlineExceeded

        var errorDescription: String? {
            switch self {
            case .responseTooLarge:
                return
                    "HTTP provider document exceeded the maximum acquisition size."

            case .deadlineExceeded:
                return
                    "HTTP provider document acquisition exceeded the deadline."
            }
        }
    }

    private class RedirectRejectingDelegate:
        NSObject,
        URLSessionTaskDelegate
    {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection
                response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler:
                @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Incrementally collects one provider document.
    ///
    /// The accumulator never grows beyond `maximumBytes`.
    /// A declared Content-Length above the cap is rejected before body
    /// accumulation; unknown-length/chunked bodies are cancelled as soon
    /// as the next received chunk would cross the cap.
    private final class BoundedLoadDelegate:
        RedirectRejectingDelegate,
        URLSessionDataDelegate
    {
        let semaphore =
            DispatchSemaphore(
                value: 0
            )

        private let lock =
            NSLock()

        private let maximumBytes:
            Int

        private var storedData =
            Data()

        private var storedResponse:
            URLResponse?

        private var storedError:
            Error?

        private var finished =
            false

        init(
            maximumBytes: Int
        ) {
            self.maximumBytes =
                maximumBytes

            super.init()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler:
                @escaping (
                    URLSession.ResponseDisposition
                ) -> Void
        ) {
            let expected =
                response.expectedContentLength

            if
                expected >= 0,
                expected
                    > Int64(
                        maximumBytes
                    )
            {
                finish(
                    error:
                        AcquisitionFailure
                            .responseTooLarge
                )

                completionHandler(
                    .cancel
                )

                return
            }

            lock.lock()

            if !finished {
                storedResponse =
                    response
            }

            lock.unlock()

            completionHandler(
                .allow
            )
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            var exceeded =
                false

            lock.lock()

            if !finished {
                let remaining =
                    maximumBytes
                    - storedData.count

                if data.count > remaining {
                    storedError =
                        AcquisitionFailure
                            .responseTooLarge

                    finished =
                        true

                    exceeded =
                        true
                } else {
                    storedData.append(
                        data
                    )
                }
            }

            lock.unlock()

            if exceeded {
                dataTask.cancel()
                semaphore.signal()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error:
                Error?
        ) {
            finish(
                error:
                    error
            )
        }

        func snapshot()
            -> (
                data: Data,
                response: URLResponse?,
                error: Error?
            )
        {
            lock.lock()
            defer {
                lock.unlock()
            }

            return (
                storedData,
                storedResponse,
                storedError
            )
        }

        private func finish(
            error: Error?
        ) {
            var shouldSignal =
                false

            lock.lock()

            if !finished {
                finished =
                    true

                storedError =
                    error

                shouldSignal =
                    true
            }

            lock.unlock()

            if shouldSignal {
                semaphore.signal()
            }
        }
    }

    /// Preserve the caller's URLSession configuration, including test
    /// URLProtocol classes, while replacing redirect behaviour with
    /// fail-closed authority semantics.
    static func makeSession(
        template:
            URLSession = .shared
    ) -> URLSession {
        URLSession(
            configuration:
                template.configuration,
            delegate:
                RedirectRejectingDelegate(),
            delegateQueue:
                nil
        )
    }

    /// Acquire a provider document with origin, size and deadline bounds.
    ///
    /// This is intentionally synchronous because the surrounding discovery
    /// source exposes a synchronous reflector snapshot. Network I/O is
    /// already performed on the source's acquisition queue in ordinary
    /// Bonjour discovery.
    static func load(
        _ url: URL,
        template:
            URLSession = .shared
    ) throws -> Data {
        try boundedLoad(
            url,
            maximumBytes:
                maximumAcquisitionBytes,
            template:
                template
        )
    }

    static func loadOpenAPISpecification(
        _ url: URL,
        template:
            URLSession = .shared
    ) throws -> Data {
        try boundedLoad(
            url,
            maximumBytes:
                maximumOpenAPISpecificationBytes,
            template:
                template
        )
    }

    static func loadObservation(_ request: URLRequest, maximumBytes: Int) throws -> Data {
        try boundedLoad(request.url!, maximumBytes: maximumBytes, template: .shared, initialRequest: request)
    }

    /// Shared bounded exchange for descriptor protocols requiring response
    /// headers (for example negotiated session identifiers). The same no-redirect,
    /// origin, response size and deadline rules apply to acquisition and calls.
    static func exchange(_ request: URLRequest, maximumBytes: Int = maximumAcquisitionBytes,
                         template: URLSession = .shared, deadline: TimeInterval = acquisitionDeadline,
                         successfulStatusRequired: Bool = true,
                         admitStart: ((_ start: () -> Void) throws -> Void)? = nil) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw RightClickError("Missing exchange target.") }
        return try boundedExchange(url, maximumBytes: maximumBytes, template: template, initialRequest: request,
            admitStart: admitStart, deadline: deadline, successfulStatusRequired: successfulStatusRequired)
    }

    /// Bounded shared invocation edge. Admission consumes authority atomically
    /// with enqueue; response collection and waiting happen after its lock.
    static func loadInvocation(_ request: URLRequest, maximumBytes: Int,
                               admitStart: (_ enqueue: () -> Void) throws -> Void) throws -> Data {
        guard let url = request.url else { throw RCIRError.invalidContract }
        return try withoutActuallyEscaping(admitStart) { start in
            try boundedLoad(url, maximumBytes: maximumBytes, template: .shared,
                            initialRequest: request, admitStart: start)
        }
    }

    private static func boundedLoad(
        _ url: URL,
        maximumBytes: Int,
        template: URLSession,
        initialRequest: URLRequest? = nil,
        admitStart: ((_ enqueue: () -> Void) throws -> Void)? = nil
    ) throws -> Data {
        try boundedExchange(url, maximumBytes: maximumBytes, template: template,
                            initialRequest: initialRequest, admitStart: admitStart).0
    }

    private static func boundedExchange(_ url: URL, maximumBytes: Int, template: URLSession,
                                        initialRequest: URLRequest?,
                                        admitStart: ((_ start: () -> Void) throws -> Void)? = nil,
                                        deadline: TimeInterval = acquisitionDeadline,
                                        successfulStatusRequired: Bool = true) throws -> (Data, HTTPURLResponse) {
        guard maximumBytes > 0, maximumBytes <= maximumOpenAPISpecificationBytes,
              deadline.isFinite, deadline > 0, deadline <= 10 else { throw RCIRError.invalidLimit }

        let configuration =
            template.configuration

        configuration
            .timeoutIntervalForRequest =
                deadline

        configuration
            .timeoutIntervalForResource =
                deadline

        let delegate =
            BoundedLoadDelegate(
                maximumBytes:
                    maximumBytes
            )

        let session =
            URLSession(
                configuration:
                    configuration,
                delegate:
                    delegate,
                delegateQueue:
                    nil
            )

        defer {
            session.invalidateAndCancel()
        }

        var request = initialRequest ?? URLRequest(url: url)

        request.timeoutInterval =
            deadline

        let task =
            session.dataTask(
                with: request
            )

        if let admitStart { try admitStart { task.resume() } }
        else { task.resume() }

        let deadlineMilliseconds =
            Int(
                deadline
                * 1_000
            )

        let wait =
            delegate.semaphore.wait(
                timeout:
                    .now()
                    + .milliseconds(
                        deadlineMilliseconds
                    )
            )

        if wait == .timedOut {
            task.cancel()

            throw AcquisitionFailure
                .deadlineExceeded
        }

        let result =
            delegate.snapshot()

        if let error =
            result.error
        {
            throw error
        }

        guard
            let response =
                result.response
                    as? HTTPURLResponse
        else {
            throw RightClickError(
                "HTTP provider document returned no HTTP response."
            )
        }

        guard
            sameOrigin(
                url,
                response.url
            )
        else {
            throw RightClickError(
                "HTTP provider response escaped the selected origin."
            )
        }

        guard
            !successfulStatusRequired || (200...299)
                .contains(
                    response.statusCode
                )
        else {
            throw RightClickError(
                "HTTP provider document returned HTTP \(response.statusCode)."
            )
        }

        // Defensive invariant. Incremental accumulation above already
        // prevents the buffer from crossing this boundary.
        guard
            result.data.count
                <= maximumBytes
        else {
            throw AcquisitionFailure
                .responseTooLarge
        }

        return (result.data, response)
    }

    /// Origin equality follows URL origin semantics:
    ///
    /// scheme + host + effective port
    static func sameOrigin(
        _ expected: URL,
        _ actual: URL?
    ) -> Bool {
        guard
            let actual,
            let expectedOrigin =
                origin(
                    expected
                ),
            let actualOrigin =
                origin(
                    actual
                )
        else {
            return false
        }

        return
            expectedOrigin.scheme
                == actualOrigin.scheme
            && expectedOrigin.host
                == actualOrigin.host
            && expectedOrigin.port
                == actualOrigin.port
    }

    private static func origin(
        _ url: URL
    ) -> (
        scheme: String,
        host: String,
        port: Int
    )? {
        guard
            let components =
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL:
                        false
                ),
            let rawScheme =
                components.scheme,
            let rawHost =
                components.host
        else {
            return nil
        }

        let scheme =
            rawScheme.lowercased()

        guard
            scheme == "http"
                || scheme == "https"
        else {
            return nil
        }

        let host =
            rawHost.lowercased()

        let effectivePort:
            Int

        if let explicit =
            components.port
        {
            effectivePort =
                explicit
        } else if scheme == "https" {
            effectivePort =
                443
        } else {
            effectivePort =
                80
        }

        return (
            scheme,
            host,
            effectivePort
        )
    }
}
