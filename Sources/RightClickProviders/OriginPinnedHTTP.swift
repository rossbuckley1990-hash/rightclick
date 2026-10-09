#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RightClickProtocol
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
public enum OriginPinnedHTTP {
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
        // Explicit witness permits subclass overrides on FoundationNetworking,
        // where inherited protocol defaults do not use Objective-C selectors.
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {}

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

        override func urlSession(
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

    public static func loadOpenAPISpecification(
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
        guard let url = request.url else { throw RightClickError("Observation request has no URL.") }
        return try boundedLoad(url, maximumBytes: maximumBytes, template: .shared, initialRequest: request, credentialFree: true)
    }

    private static func boundedLoad(
        _ url: URL,
        maximumBytes: Int,
        template: URLSession,
        initialRequest: URLRequest? = nil,
        credentialFree: Bool = false
    ) throws -> Data {
        precondition(
            maximumBytes > 0
        )

        let configuration = credentialFree ? URLSessionConfiguration.ephemeral : template.configuration
        if credentialFree {
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
        }

        configuration
            .timeoutIntervalForRequest =
                acquisitionDeadline

        configuration
            .timeoutIntervalForResource =
                acquisitionDeadline

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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if credentialFree { request.httpShouldHandleCookies = false }

        request.timeoutInterval =
            acquisitionDeadline

        let task =
            session.dataTask(
                with: request
            )

        task.resume()

        let deadlineMilliseconds =
            Int(
                acquisitionDeadline
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
            (200...299)
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

        return result.data
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
