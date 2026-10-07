import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RightClickARD

@main
struct RightClickARDProbe {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (Data?, URLResponse?, Error?) = (nil, nil, nil)

        func set(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            stored = (data, response, error)
            lock.unlock()
        }

        func get() -> (Data?, URLResponse?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first

        if mode == "live-hf" {
            try liveHuggingFaceGate(resolveArtifacts: false)
            return
        }

        if mode == "live-hf-resolve" {
            try liveHuggingFaceGate(resolveArtifacts: true)
            return
        }

        try portableAcquisitionGate()
    }

    private static func portableAcquisitionGate() throws {
        let response = Data(
            """
            {
              "results": [
                {
                  "identifier": "urn:air:example.com:api:records",
                  "displayName": "Portable Records API",
                  "type": "application/openapi+json",
                  "data": {
                    "openapi": "3.0.3",
                    "info": {
                      "title": "Portable Records API",
                      "version": "1.0.0"
                    },
                    "servers": [
                      {
                        "url": "https://api.example.com"
                      }
                    ],
                    "paths": {}
                  },
                  "score": 100,
                  "source": "linux-probe"
                }
              ],
              "referrals": []
            }
            """.utf8
        )

        let decoded = try ARDAcquisition.decodeSearchResponse(response)
        let candidates = ARDAcquisition.openAPICandidates(in: decoded)

        guard
            candidates.count == 1,
            let specification = candidates[0].inlineSpecification,
            ARDAcquisition.literalOpenAPIBaseURL(from: specification) == "https://api.example.com"
        else {
            throw NSError(
                domain: "RightClickARDProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Portable ARD acquisition invariant failed."]
            )
        }

        print("ARD_PORTABLE_ACQUISITION=PASS")
        print("candidate_identifier=\(candidates[0].identifier)")
        print("base_url=https://api.example.com")
    }

    private static func liveHuggingFaceGate(resolveArtifacts: Bool) throws {
        let endpoint = URL(string: "https://huggingface-hf-discover.hf.space/search")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try ARDAcquisition.searchRequest(
            query: "image generation",
            pageSize: 5,
            federation: "none"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let data = try synchronousData(for: request, timeout: 30)
        let decoded = try ARDAcquisition.decodeSearchResponse(data)

        guard !decoded.results.isEmpty else {
            throw NSError(
                domain: "RightClickARDProbe",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Hugging Face ARD search returned no results."]
            )
        }

        print("HF_DISCOVER_SEARCH_RESPONSE=PASS")
        print("result_count=\(decoded.results.count)")
        print("first_type=\(decoded.results[0].type)")
        print("first_identifier=\(decoded.results[0].identifier)")

        guard resolveArtifacts else {
            return
        }

        for (index, result) in decoded.results.enumerated() {
            var object: [String: Any] = [
                "index": index,
                "identifier": result.identifier,
                "displayName": result.displayName,
                "type": result.type,
                "score": result.score,
                "source": result.source,
            ]

            if let url = result.url {
                object["url"] = url
            }

            if let inlineData = result.inlineData {
                object["inlineDataBase64"] = inlineData.base64EncodedString()
                if
                    let json = try? JSONSerialization.jsonObject(with: inlineData),
                    JSONSerialization.isValidJSONObject(json),
                    let canonical = try? JSONSerialization.data(
                        withJSONObject: json,
                        options: [.sortedKeys]
                    )
                {
                    object["inlineJSONBase64"] = canonical.base64EncodedString()
                }
            }

            let encoded = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )

            print("HF_RESULT_\(index)_BASE64=\(encoded.base64EncodedString())")
        }

        print("HF_SKILL_RESOLUTION=PASS")
    }

    private static func synchronousData(
        for request: URLRequest,
        timeout: Int
    ) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(timeout)
        configuration.timeoutIntervalForResource = TimeInterval(timeout + 10)

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        let task = session.dataTask(with: request) { data, response, error in
            box.set(data: data, response: response, error: error)
            semaphore.signal()
        }

        task.resume()

        guard semaphore.wait(timeout: .now() + .seconds(timeout + 5)) == .success else {
            task.cancel()
            throw NSError(
                domain: "RightClickARDProbe",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Remote request timed out."]
            )
        }

        let result = box.get()

        if let error = result.2 {
            throw error
        }

        guard
            let response = result.1 as? HTTPURLResponse,
            (200...299).contains(response.statusCode),
            let data = result.0
        else {
            throw NSError(
                domain: "RightClickARDProbe",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Remote request returned no accepted response."]
            )
        }

        return data
    }
}
