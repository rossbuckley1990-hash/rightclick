import Foundation
import RightClickARD

@main
struct RightClickARDProbe {
    static func main() throws {
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
            ARDAcquisition.literalOpenAPIBaseURL(
                from: specification
            ) == "https://api.example.com"
        else {
            throw NSError(
                domain: "RightClickARDProbe",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Portable ARD acquisition invariant failed."
                ]
            )
        }

        print("ARD_PORTABLE_ACQUISITION=PASS")
        print("candidate_identifier=\(candidates[0].identifier)")
        print("base_url=https://api.example.com")
    }
}
